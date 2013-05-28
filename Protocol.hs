{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

module Protocol where

import Control.Applicative
import Control.Exception
import Control.Monad
import Control.Monad.Reader
import Control.Concurrent
import qualified Data.ByteString as B
import Data.Serialize
import System.Environment
import Data.Word
import System.IO
import Network.Socket
import Network.BSD

import Dispatch
import Message
import Compat

data ProtocolState
  = ProtocolState {
    protoFwdOpt   :: !FwdOption,
    protoReadMsg  :: !ReadMsg,
    protoWriteMsg :: !WriteMsg,
    protoWriteLog :: !(String -> IO ()),
    protoChanMan  :: !(ChanManager Message)
  }

type WriteMsg = Message -> IO ()
type ReadMsg = IO Message
type ProtocolM = ReaderT ProtocolState IO

runProtocol = flip runReaderT

-- Various protocol-related handlers.
-- XXX: some of them could use ReaderT
-- XXX: error handling

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

-- Initialize chanMan: drop msg whose chanId is unknown, and redirect
-- known msg to their corresponding chans.
initListenerChanMan readMsg chanMan = forkIO $ forever $ do
  msg <- readMsg
  mbChan <- lookupChanById chanMan (connId msg)
  case mbChan of
    Nothing -> return () -- Drop this msg
    Just chan -> writeChan chan msg

-- XXX: use ReaderT?
runLocalServer :: ((Socket, SockAddr) -> ProtocolM ()) -> ProtocolM ()
runLocalServer handler = do
  -- Read many things...
  port <- asks (fwdListenPort . protoFwdOpt)
  readMsg <- asks protoReadMsg
  chanMan <- asks protoChanMan
  writeLog <- asks protoWriteLog
  protoState <- ask

  liftIO $ do
    -- Listen on local port
    listenSock <- mkListeningSock port
    initListenerChanMan readMsg chanMan
    writeLog $ "Start listen on " ++ show port
    -- Socks5 server accept loop
    forever $ do
      conn@(cliSock, hostPort) <- accept listenSock
      writeLog $ show hostPort ++ " connected."
      -- Client connected
      forkIO $ (runReaderT (handler conn) protoState)

handleSocks5ClientReq :: (Socket, SockAddr) -> ProtocolM ()
handleSocks5ClientReq (cliSock, sockAddr) = do
  chanMan <- asks protoChanMan
  writeMsg <- asks protoWriteMsg
  protoState <- ask

  liftIO $ do
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
        writeMsg (Disconnect chanId)
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
        let
          Just usingHostPort = mbHostPort
        socks5TellConnSuccess cliH usingHostPort

        -- Connection succeeded: start piping loop
        runProtocol protoState $
          runFwdLoop cleanUpChan cliH chanId chan (show sockAddr)

runFwdLoop rawCleanUp cliH chanId chan cliName = do
  writeMsg <- asks protoWriteMsg
  writeLog <- asks protoWriteLog
  liftIO $ do
    doCleanUp <- mkIdempotent rawCleanUp

    let
      handleErr (e :: SomeException) = doCleanUp

    forkIO $ (`catchEx` handleErr) $ forever $ do
      someData <- hGetSome cliH 4096
      case B.null someData of
        False -> writeMsg (WriteTo chanId someData)
        True -> do
          writeLog $ "[runFwdLoop] " ++ cliName ++ " closed"
          throwIO $ userError "remote closed"

    forkIO $ (`catchEx` handleErr) $ forever $ do
      msg <- readChan chan
      case msg of
        WriteTo _ someData -> B.hPut cliH someData
        Disconnect _ -> do
          writeLog $ "[runFwdLoop] got disconnect msg"
          throwIO $ userError "got disconnect msg"

    return ()

handleLocalFwdReq :: (Socket, SockAddr) -> ProtocolM ()
handleLocalFwdReq (cliSock, sockAddr) = do
  host <- asks (fwdConnectHost . protoFwdOpt)
  port <- asks (fwdConnectPort . protoFwdOpt)
  chanMan <- asks protoChanMan
  writeMsg <- asks protoWriteMsg
  protoState <- ask

  liftIO $ do
    cliH <- socketToHandle cliSock ReadWriteMode
    hSetBuffering cliH NoBuffering

    (chanId, chan) <- mkNewChan chanMan

    let
      cleanUpCliConn = do
        try (shutdown cliSock ShutdownBoth) :: IO (Either IOException ())
        hClose cliH

      cleanUpChan = do
        writeMsg (Disconnect chanId)
        delChanById chanMan chanId
        cleanUpCliConn

    writeMsg (Connect chanId (Right host) port)
    (ConnectResult _ succ mbHostPort) <- readChan chan
    if not succ
      then do
        -- Connection failed
        cleanUpChan

      else do
        -- Connection succeeded: start piping loop
        runProtocol protoState $ do
          runFwdLoop cleanUpChan cliH chanId chan (show sockAddr)

runPortForwarder :: ProtocolM ()
runPortForwarder = do
  -- Initialize chanMan: drop msg whose chanId is unknown and is not a connect
  -- message. Create a new channel for unknown connect message. Forward msg to
  -- its corresponding channel otherwise.
  readMsg <- asks protoReadMsg
  chanMan <- asks protoChanMan
  writeLog <- asks protoWriteLog
  protoState <- ask

  liftIO $ forever $ do
    msg <- readMsg
    case msg of
      (Connect {..}) -> do
        chan <- mkChanById chanMan connId
        forkIO (runReaderT (handleResolve msg connId chan) protoState)
        return ()
      _ -> do
        mbChan <- lookupChanById chanMan (connId msg)
        case mbChan of
          Nothing -> return () -- Drop it
          Just chan -> writeChan chan msg
  return ()
  where
    handleResolve :: Message -> ChanId -> Chan Message -> ProtocolM ()
    handleResolve msg@(Connect {..}) chanId chan = do
      writeLog <- asks protoWriteLog
      writeMsg <- asks protoWriteMsg
      chanMan <- asks protoChanMan
      protoState <- ask
      liftIO $ case connHost of
        Left ipv4Addr ->
          runReaderT (handleConnect msg chanId chan ipv4Addr) protoState
        Right hostName -> do

          liftIO $ do
            eiAddress <- try $ hostAddresses <$> getHostByName hostName
            case eiAddress of
              Left (e :: SomeException) -> do
                -- Cannot resolve host name
                writeLog $ "Cannot resolve hostname " ++
                           pprHostPort connHost connPort
                writeMsg (ConnectResult connId False Nothing)
                delChanById chanMan connId
              Right (ipv4Addr:_) ->
                runReaderT (handleConnect msg chanId chan ipv4Addr) protoState

    handleConnect :: Message -> ChanId -> Chan Message ->
                     HostAddress -> ProtocolM ()
    handleConnect (Connect {..}) chanId chan addr = do
      writeLog <- asks protoWriteLog
      writeMsg <- asks protoWriteMsg
      chanMan <- asks protoChanMan
      protoState <- ask

      liftIO $ do
        let sockAddr = SockAddrInet connPort addr
            hostPort = pprHostPort connHost connPort
        writeLog $ "Connecting to " ++ hostPort ++ "..."
        dstSock <- mkReusableSock
        connResult <- try (connect dstSock sockAddr)
        case connResult of
          Left (e :: IOException) -> do
            writeLog $ "Failed to connect to " ++ hostPort
            -- Connection failed
            writeMsg (ConnectResult connId False Nothing)

          Right _ -> do
            writeLog $ "Connected to " ++ hostPort
            SockAddrInet portUsed addrUsed <- getSocketName dstSock
            dstH <- socketToHandle dstSock ReadWriteMode
            hSetBuffering dstH NoBuffering
            -- Connection opened
            writeMsg (ConnectResult connId True
                                    (Just (fromIntegral addrUsed,
                                           fromIntegral portUsed)))

            let 
              reallyCleanUp = do
                writeLog $ "[cleanUp] Done for id=" ++ show chanId
                writeMsg (Disconnect chanId)
                shutdown dstSock ShutdownBoth
                hClose dstH
                delChanById chanMan chanId

            runProtocol protoState $ do
              runFwdLoop reallyCleanUp dstH chanId chan hostPort

