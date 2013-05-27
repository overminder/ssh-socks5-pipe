{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

import Control.Applicative
import Control.Exception
import Control.Monad.Reader
import Control.Concurrent
import qualified Data.ByteString as B
import qualified Data.Map as M
import Data.Serialize
import System.Environment
import System.IO
import System.Info
import System.Process
import Network.Socket
import Network.BSD
import qualified Data.String.Utils as SU
import Data.Word

import Dispatch
import Protocol
import Compat

wLog lock s = do
  withMVar lock $ \ () -> hPutStrLn stderr $ "[Server] " ++ s

main = do
  args <- getArgs
  case args of
    [user, host, remotePath, fwdType, fwdArg] -> do
      logLock <- newMVar ()
      let fwdOpt = parseFwdOpt fwdType fwdArg
          writeLog = wLog logLock
      writeLog (show fwdOpt)
      rwMsg <- mkSshTransport user host 22 remotePath
      runLocalPart rwMsg fwdOpt writeLog
    _ -> hPutStr stderr usage

  where
    usage = unlines [ "Usage: Server USER HOST REMOTE-PATH FWD-SPEC"
                    , "where FWD-SPEC can be:"
                    , "  -D LOCALPORT"
                    , "  -DR REMOTEPORT"
                    , "  -L LOCALPORT:REMOTEHOST:REMOTEPORT"
                    , "  -R REMOTEPORT:LOCALHOST:LOCALPORT"
                    ]

parseFwdOpt :: String -> String -> FwdOption
parseFwdOpt fwdType = case fwdType of
  "-D"  -> FwdLocalDynamic . mkPortNum . read
  "-DR" -> FwdRemoteDynamic . mkPortNum . read
  "-L"  -> splitArgWith FwdLocal
  "-R"  -> splitArgWith FwdRemote
  where
    splitArgWith constr fwdArg = let (p, h, p') = splitFwdArg fwdArg
                                  in constr (mkPortNum p) h (mkPortNum p')

    splitFwdArg fwdArg = (read port1, host, read port2)
      where
        [port1, host, port2] = SU.split ":" fwdArg

    mkPortNum :: Int -> PortNumber
    mkPortNum = fromIntegral

mkSshTransport :: String -> String -> Int -> String ->
                  IO (IO Message, Message -> IO ())
mkSshTransport user host port command = do
  (Just sshIn, Just sshOut, _, _) <- createProcess $
    sshProc { std_in = CreatePipe, std_out = CreatePipe }

  forM_ [sshIn, sshOut] $ \ h -> do
    hSetBuffering h NoBuffering
    hSetBinaryMode h True

  rChan <- newChan
  wChan <- newChan

  forkIO $ dispatchToChan sshOut rChan
  forkIO $ dispatchFromChan wChan sshIn

  -- SSH connection established.
  return (readChan rChan, writeChan wChan)
  where
    sshProc
      | os == "linux"   = proc "/usr/bin/ssh" [ user ++ "@" ++ host
                                              , "-p", show port
                                              , command
                                              ]
      | os == "mingw32" = proc "./plink.exe" [ "-l", user, host
                                             , "-i", "./putty-priv-key"
                                             , "-P", show port
                                             , command
                                             ]
      | otherwise       = error $ "sshProc: unsupported os: " ++ os

runLocalPart (readMsg, writeMsg) fwdOpt writeLog = do
  chanMan <- mkChanManager
  writeMsg (HandShake fwdOpt)
  case fwdOpt of
    FwdLocalDynamic {..} -> do
      sock <- mkListeningSock fwdListenPort
      -- Local socks5 server started
      runLocalSocks5 sock chanMan (readMsg, writeMsg) writeLog
    FwdRemoteDynamic {..} -> do
      error $ "runLocalPart: remote dynamic not supported yet"
    FwdLocal {..} -> do
      sock <- mkListeningSock fwdListenPort
      -- Local port forwarder started
      return ()
    FwdRemote {..} -> do
      -- Listen on ssh transport for connection request
      error $ "runLocalPart: remote forwarding not supported yet"

  where
    mkListeningSock port = do
      sock <- mkReusableSock
      bindSocket sock (SockAddrInet port iNADDR_ANY)
      listen sock 5
      return sock

-- XXX: use ReaderT?
runLocalSocks5 sock chanMan (readMsg, writeMsg) writeLog = do
  -- Initialize chanMan: drop msg whose chanId is unknown, and redirect
  -- known msg to their corresponding chans.
  forkIO $ forever $ do
    msg <- readMsg
    mbChan <- lookupChanById chanMan (connId msg)
    case mbChan of
      Nothing -> return () -- Drop this msg
      Just chan -> writeChan chan msg

  -- Socks5 server accept loop
  forever $ do
    conn <- accept sock
    writeLog $ show conn ++ " connected."
    -- Client connected
    forkIO $ handleConn conn
  where
    handleConn (cliSock, _) = do
      cliH <- socketToHandle cliSock ReadWriteMode
      hSetBuffering cliH NoBuffering

      let
        cleanUpCliConn = do
          try (shutdown cliSock ShutdownBoth) :: IO (Either IOException ())
          hClose cliH

      -- XXX: error handling
      (host, port) <- socks5HandShake cliH
      (chanId, chan) <- mkNewChan chanMan

      let
        cleanUpChan = do
          delChanById chanMan chanId
          cleanUpCliConn

      writeMsg (Connect chanId host port)
      (ConnectResult _ succ mbHostPort) <- readChan chan
      if not succ
        then do
          -- Connection failed
          socks5TellConnFailure cliH
          cleanUpChan

        else do
          -- Connection succeeded: start piping loop
          doCleanUp <- mkIdempotent cleanUpChan

          let
            Just usingHostPort = mbHostPort
            handleErr (e :: SomeException) = doCleanUp

          socks5TellConnSuccess cliH usingHostPort

          forkIO $ (`catchEx` handleErr) $ forever $ do
            someData <- B.hGetSome cliH 4096
            case B.null someData of
              False -> writeMsg (WriteTo chanId someData)
              True -> doCleanUp

          forkIO $ (`catchEx` handleErr) $ forever $ do
            msg <- readChan chan
            case msg of
              WriteTo _ someData -> B.hPut cliH someData
              Disconnect _ -> doCleanUp

          return ()

socks5HandShake :: Handle -> IO (ConnHost, PortNumber)
socks5HandShake h = do
  -- Initialization phase (rfc1928, section 3)
  5 <- hGetByte h                         -- Protocol version (5)
  nMethods <- hGetByte h                  -- number of supported auth options
  methods <- B.hGet h nMethods            -- XXX should check for no-auth (0)

  B.hPutStr h (B.pack [5, 0])             -- Reply: Ver (5) and no-auth (0)

  -- Accepting request (rfc1928, section 4)
  5 <- hGetByte h                         -- Again protocol version (5)
  1 <- hGetByte h                         -- Command (conn/bind/upd-assoc)
                                          -- We only support conn (1) here
  0 <- hGetByte h                         -- Reserved field, should be zero
  addrType <- hGetByte h

  -- Address resolving (rfc1928, section 5)
  dstHost <- case addrType of
    1 -> do
      -- XXX: this rely on the endianess of the machine
      Right ipv4Addr <- decode . B.reverse <$> B.hGet h 4 ::
                        IO (Either String Word32)
      return (Left $ fromIntegral ipv4Addr)
    3 -> do
      domainNameLen <- hGetByte h
      Right . decodeAscii <$> B.hGet h domainNameLen
      -- XXX: put gethostbyname into remote side since GFW does DNS spoofing.
      --(hostName:_) <- hostAddresses <$> getHostByName domainName
    4 -> error "socks5HandShake: addrType = 4, ipv6 not supported."
    _ -> error $ "socks5HandShake: addrType = " ++ show addrType

  Right dstPort16 <- decode <$> B.hGet h 2 :: IO (Either String Word16)
  return (dstHost, fromIntegral dstPort16)

socks5TellConnFailure h = do
  -- Tell the client about the failure (rfc1928, section 6)
  B.hPutStr h (B.pack [ 5 -- Version
                      , 4 -- Host unreachable (Actually we can
                          -- be a bit more specific)
                      ])

socks5TellConnSuccess h (usingHost, usingPort) = do
  let
    packedAddr = encode (fromIntegral usingHost :: Word32)
    packedPort = encode (fromIntegral usingPort :: Word16)
  B.hPutStr h (B.pack [ 5 -- Version
                      , 0 -- Succeeds
                      , 0 -- RSV
                      , 1 -- Using ipv4 addr
                      ] `B.append` packedAddr
                        `B.append` packedPort)

