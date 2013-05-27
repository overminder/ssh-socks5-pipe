{-# LANGUAGE OverloadedStrings, ScopedTypeVariables,
             ForeignFunctionInterface #-}

import Control.Applicative
import Control.Exception
import Control.Monad.Reader
import Control.Concurrent
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map as M
import Data.Binary
import Data.IORef
import Data.Char
import System.Environment
import System.FilePath
import System.IO
import System.Info
import System.Process
import Network.Socket
import Network.BSD

import Message
import Compat

sshPort = 22

listenPort = 1080

data ServerState
  = ServerState {
    servChanMap :: !(MVar (M.Map Int (Chan Message))),
    servWriteMsg :: !(Message -> IO ()),
    servMkNewChan :: !(IO (Int, Chan Message)),
    servRemoveChan :: !(Int -> IO ())
  }

main = do
  args <- getArgs
  case args of
    [user, host, cmd] -> makeTransport user host sshPort cmd
    _ -> putStrLn "Synopsis: LocalServer USER HOST COMMAND"

startServer = do
  sock <- liftIO $ do
    sock <- mkReusableSock
    bindSocket sock (SockAddrInet listenPort iNADDR_ANY)
    listen sock 5
    putStrLn "Socks5 server started."
    return sock
  forever $ acceptLoop sock

acceptLoop sock = do
  servState <- ask
  liftIO $ do
    conn <- accept sock
    putStrLn $ show conn ++ " connected."
    forkIO_ $ (runReaderT (handleConn conn) servState)

forkIO_ m = forkIO m >> return ()

handleConn (clientSock, _) = do
  writeMsg <- asks servWriteMsg
  mkNewChan <- asks servMkNewChan
  removeChan <- asks servRemoveChan
  liftIO $ do
    clientHandle <- socketToHandle clientSock ReadWriteMode
    hSetBuffering clientHandle NoBuffering

    -- Initialization phase (rfc1928, section 3)
    5 <- hGetByte clientHandle              -- Protocol version (5)
    nMethods <- hGetByte clientHandle       -- number of supported auth options
    methods <- B.hGet clientHandle nMethods -- XXX should check for no-auth (0)

    B.hPutStr clientHandle (B.pack [5, 0])  -- Reply: Ver (5) and no-auth (0)

    -- Accepting request (rfc1928, section 4)
    5 <- hGetByte clientHandle              -- Again protocol version (5)
    1 <- hGetByte clientHandle              -- Command (conn/bind/upd-assoc)
                                            -- We only support conn (1) here
    0 <- hGetByte clientHandle              -- Reserved field, should be zero
    addrType <- hGetByte clientHandle

    -- Address resolving (rfc1928, section 5)
    dstHost <- case addrType of
      1 -> do
        ipv4Addr <- decode . BL.reverse <$> BL.hGet clientHandle 4 :: IO Word32
        return (Left $ fromIntegral ipv4Addr)
      3 -> do
        domainNameLen <- hGetByte clientHandle
        Right . decodeAscii <$> B.hGet clientHandle domainNameLen
        -- XXX: put gethostbyname into remote side since GFW does DNS spoofing.
        --(hostName:_) <- hostAddresses <$> getHostByName domainName
      4 -> error "handleConn: addrType = 4, ipv6 not supported."
      _ -> error $ "handleConn: addrType = " ++ show addrType

    --dstAddrName <- inet_ntoa packedDstAddr
    dstPort' <- decode <$> BL.hGet clientHandle 2 :: IO Word16
    let dstPort = fromIntegral dstPort'

    showHostPort <- pprHostPort dstHost dstPort

    putStrLn $ "Requested dst is " ++ showHostPort

    -- Ask for connection
    (chanId, chan) <- mkNewChan
    writeMsg (Connect chanId dstHost dstPort)
    
    -- Wait for reply
    (ConnectResult _ succ mbHostPort) <- readChan chan
    if succ
      then do
        let Just (usingHost, usingPort) = mbHostPort
        putStrLn $ "Connected to requested dst " ++ showHostPort
        usingHostName <- inet_ntoa (fromIntegral usingHost)
        putStrLn $ "Server bound addr/port: " ++ usingHostName ++
                   ":" ++ show usingPort

        -- Tell client about the success
        let packedPort = encode (fromIntegral usingPort :: Word16)
            packedAddr = encode (fromIntegral usingHost :: Word32)
        BL.hPutStr clientHandle (BL.pack [ 5 -- Version
                                         , 0 -- Succeeds
                                         , 0 -- Reserved
                                         , 1 -- Using ipv4 addr
                                         ] `BL.append` packedAddr
                                           `BL.append` packedPort)

        -- Enter recv/send loop
        let
          reallyCleanUp = do
            putStrLn $ "Done for request " ++ showHostPort
            removeChan chanId
            try (shutdown clientSock ShutdownBoth) :: IO (Either IOException ())
            hClose clientHandle

        cleanUpVar <- newMVar reallyCleanUp

        let
          cleanUp' = do
            todo <- swapMVar cleanUpVar (return ())
            todo

          cleanUp (e :: IOException) = cleanUp'

        -- Read from client and send to ssh
        forkIO_ $ (`Control.Exception.catch` cleanUp) $ forever $ do
          someData <- B.hGetSome clientHandle 4096
          case B.length someData of
            0 -> do
              -- XXX remove chan from the map
              cleanUp'
            _ -> do
              writeMsg (WriteTo chanId someData)

        -- Read from ssh and send to client
        forkIO_ $ (`Control.Exception.catch` cleanUp) $ forever $ do
          msg <- readChan chan
          case msg of
            WriteTo _ someData -> do
              B.hPut clientHandle someData
            Disconnect _ -> do
              cleanUp'

      else do
        putStrLn $ "Connection failed for " ++ showHostPort
        -- Tell the client about the failure (rfc1928, section 6)
        B.hPutStr clientHandle (B.pack [ 5 -- Version
                                       , 4 -- Host unreachable (Actually we can
                                           -- be a bit more specific)
                                       ])
        removeChan chanId
        try (shutdown clientSock ShutdownBoth) :: IO (Either IOException ())
        hClose clientHandle

getSshProc login host port command
  | os == "linux"   = proc "/usr/bin/ssh" [ login ++ "@" ++ host, "-p"
                                          , show port, command
                                          ]
  | os == "mingw32" = proc "./plink.exe" [ "-l", login, host
                                         , "-i", "./putty-priv-key"
                                         , command
                                         ]
  | otherwise       = error $ "getSshProc: unsupported os: " ++ os

makeTransport login host port command = do
  let sshProc = getSshProc login host port command
  (Just sshIn, Just sshOut, _, _) <- createProcess $
    sshProc { std_in = CreatePipe, std_out = CreatePipe }

  forM_ [sshIn, sshOut] $ \ h -> do
    hSetBuffering h NoBuffering
    hSetBinaryMode h True

  putStrLn "SSH connection established."

  writeLock <- newMVar ()
  chanRef <- newMVar M.empty
  readBuf <- newIORef B.empty
  uniqueRef <- newMVar 0

  let
    writeMsg msg = let msgStr = serialize msg
                    in withMVar writeLock $ \ () ->
                         BL.hPut sshIn msgStr

    mkUnique = modifyMVar uniqueRef $ \ i -> do
      return (i + 1, i + 1)

    mkNewChan = do
      chanId <- mkUnique
      chan <- newChan
      totalChan <- modifyMVar chanRef $ \ chanMap -> do
        let newChanMap = M.insert chanId chan chanMap
        return (newChanMap, M.size newChanMap)
      putStrLn $ "[mkNewChan] id=" ++ show chanId ++ ", totalChan=" ++
                 show totalChan
      return (chanId, chan)

    removeChan chanId = do
      totalChan <- modifyMVar chanRef $ \ chanMap -> do
        let newChanMap = M.delete chanId chanMap
        return (newChanMap, M.size newChanMap)
      putStrLn $ "[removeChan] id=" ++ show chanId ++ ", totalChan=" ++
                 show totalChan

    initState = ServerState {
      servChanMap = chanRef,
      servWriteMsg = writeMsg,
      servMkNewChan = mkNewChan,
      servRemoveChan = removeChan
    }

  -- Start socks5 part
  forkIO_ (runReaderT startServer initState)

  -- Start message dispatcher
  forever $ do
    bs <- B.append <$> readIORef readBuf <*> B.hGetSome sshOut 4096
    let (rest, msgs) = deserialize (toLazy bs)
    writeIORef readBuf (toStrict rest)
    forkIO_ (runReaderT (mapM_ handleMsg msgs) initState)

handleMsg msg = do
  let chanId = connId msg
  chanRef <- asks servChanMap
  liftIO $ withMVar chanRef $ \ chanMap -> do
    --putStrLn $ "Got msg " ++ show msg
    case M.lookup chanId chanMap of
      Just chan -> writeChan chan msg
      Nothing ->
        -- Channel was closed
        return ()

hGetByte :: Num a => Handle -> IO a
hGetByte h = fromIntegral . B.head <$> B.hGet h 1

decodeAscii = map (chr . fromIntegral) . B.unpack

