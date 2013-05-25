{-# LANGUAGE ScopedTypeVariables #-}

import Data.Binary
import Data.Char
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString as Bx

import Control.Applicative
import Control.Monad
import Control.Concurrent
import Control.Concurrent.MVar

import Network.BSD
import Network.Socket
import Network.Socket.Splice

import System.IO
import System.IO.Unsafe
import System.Environment
import Control.Exception

-- hack, since data.binary uses lazy bytestring by default but
-- hGetSome is only supported in strict bytestring
hGetSome' h i = do
  x <- Bx.hGetSome h i
  let r = Bx.unpack x
      x' = B.pack r
  return x'

forkIO_ m = forkIO m >> return ()

mkReusableSock = do
  proto <- getProtocolNumber "tcp"
  sock <- socket AF_INET Stream proto
  setSocketOption sock ReuseAddr 1
  return sock

main = do
  args <- getArgs

  sock <- mkReusableSock
  bindSocket sock (SockAddrInet 1080 iNADDR_ANY)
  listen sock 5
  putStrLn "Server started."
  forever $ mainLoop sock

mainLoop sock = do
  conn <- accept sock
  putStrLn $ show conn ++ " connected."
  forkIO_ $ handleConn conn

hGetByte :: Num a => Handle -> IO a
hGetByte h = do
  bs <- B.hGet h 1
  let [b] = B.unpack bs
  return (fromIntegral b)

decodeAscii :: B.ByteString -> String
decodeAscii = map (chr . fromIntegral) . B.unpack

handleConn (clientSock, _) = do
  clientHandle <- socketToHandle clientSock ReadWriteMode
  hSetBuffering clientHandle NoBuffering

  -- Initialization phase (rfc1928, section 3)
  5 <- hGetByte clientHandle              -- Protocol version (5)
  nMethods <- hGetByte clientHandle       -- number of supported auth options
  methods <- B.hGet clientHandle nMethods -- XXX should check for no-auth (0)

  B.hPutStr clientHandle (B.pack [5, 0])  -- Reply: Version (5) and no-auth (0)
  hFlush clientHandle

  -- Accepting request (rfc1928, section 4)
  5 <- hGetByte clientHandle              -- Again protocol version (5)
  1 <- hGetByte clientHandle              -- Command (conn/bind/upd-assoc)
                                          -- We only support conn (1) here
  0 <- hGetByte clientHandle              -- Reserved field, should be zero
  addrType <- hGetByte clientHandle

  -- Address resolving (rfc1928, section 5)
  packedDstAddr <- case addrType of
    1 -> liftM (decode . B.reverse) (B.hGet clientHandle 4)
    3 -> do
      domainNameLen <- hGetByte clientHandle
      domainName <- liftM decodeAscii (B.hGet clientHandle domainNameLen)
      (hostName:_) <- hostAddresses <$> getHostByName domainName
      return hostName
    4 -> error "handleConn: addrType = 4, ipv6 not supported."
    _ -> error $ "handleConn: addrType = " ++ show addrType

  dstAddrName <- inet_ntoa packedDstAddr
  dstPort <- liftM decode (B.hGet clientHandle 2) :: IO Word16

  putStrLn $ "Requested dst is " ++ dstAddrName ++ ":" ++ show dstPort

  -- Evaluating the request by connecting to the dst
  dstSock <- mkReusableSock

  -- XXX: Is this a blocking call?
  -- XXX: port number should be big-endian so don't use PortNum ctor
  connResult <- try (connect dstSock
                             (SockAddrInet (fromIntegral dstPort)
                                           packedDstAddr))
  case connResult of
    Left (e :: IOException) -> do
      putStrLn $ "Connection failed for " ++ dstAddrName ++
                 ":" ++ show dstPort
      -- Tell the client about the failure (rfc1928, section 6)
      B.hPutStr clientHandle (B.pack [ 5 -- Version
                                     , 4 -- Host unreachable (Actually we can
                                         -- be a bit more specific)
                                     ])
      hClose clientHandle

    Right _ -> do
      dstHandle <- socketToHandle dstSock ReadWriteMode
      hSetBuffering dstHandle NoBuffering

      putStrLn $ "Connected to requested dst (" ++ dstAddrName ++
                 ":" ++ show dstPort ++ ")"

      -- Tell the client that dst is connected (rfc1928, section 6)
      SockAddrInet portUsed addrUsed <- getSocketName dstSock
      addrUsedName <- inet_ntoa addrUsed
      putStrLn $ "Server bound addr/port: " ++ addrUsedName ++
                 ":" ++ show portUsed
      let packedPort = encode (fromIntegral portUsed :: Word16)
          packedAddr = encode (fromIntegral addrUsed :: Word32)
      B.hPutStr clientHandle (B.pack [ 5 -- Version
                                     , 0 -- Succeeds
                                     , 0 -- Reserved
                                     , 1 -- Using ipv4 addr
                                     ] `B.append` packedAddr
                                       `B.append` packedPort)
      hFlush clientHandle

      let reallyCleanUp = do
            putStrLn $ "Done for request " ++ dstAddrName ++
                       ":" ++ show dstPort
            shutdown clientSock ShutdownBoth
            hClose clientHandle
            hClose dstHandle

      cleanUpVar <- newMVar reallyCleanUp

      let cleanUp (e :: SomeException) = do
            todo <- swapMVar cleanUpVar (return ())
            todo
          dstSockPair = (dstSock, Just dstHandle)
          cliSockPair = (clientSock, Just clientHandle)

      void . forkIO . tryWith cleanUp $! splice 1024 dstSockPair cliSockPair
      void . forkIO . tryWith cleanUp $! splice 1024 cliSockPair dstSockPair

