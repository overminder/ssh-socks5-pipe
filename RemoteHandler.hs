{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

import Control.Applicative
import Control.Concurrent
import Control.Monad
import qualified Data.ByteString as B
import Network.Socket
import Network.BSD
import System.IO
import System.Exit
import Control.Exception

import Dispatch
import Protocol
import Compat

wLog lock s = do
  withMVar lock $ \ () -> hPutStrLn stderr $ "[Remote] " ++ s

main = do
  logLock <- newMVar ()
  (readMsg, writeMsg) <- mkStdIOTransport
  (HandShake fwdOpt) <- readMsg
  let writeLog = wLog logLock
  writeLog (show fwdOpt)
  chanMan <- mkChanManager

  case fwdOpt of
    FwdLocalDynamic {..} -> do
      runPortForwarder (readMsg, writeMsg) chanMan writeLog
    _ -> writeLog $ "not supported yet: " ++ show fwdOpt

mkStdIOTransport :: IO (IO Message, Message -> IO())
mkStdIOTransport = do
  forM_ [stdin, stdout] $ \ h -> do
    hSetBuffering h NoBuffering
    hSetBinaryMode h True

  rChan <- newChan
  wChan <- newChan

  forkIO $ dispatchToChan stdin rChan
  forkIO $ dispatchFromChan wChan stdout

  return (readChan rChan, writeChan wChan)

runPortForwarder (readMsg, writeMsg) chanMan writeLog = do
  -- Initialize chanMan: drop msg whose chanId is unknown and is not a connect
  -- message. Create a new channel for unknown connect message. Forward msg to
  -- its corresponding channel otherwise.
  forever $ do
    msg <- readMsg
    case msg of
      (Connect {..}) -> do
        chan <- mkChanById chanMan connId
        forkIO $ handleResolve msg connId chan
        return ()
      _ -> do
        mbChan <- lookupChanById chanMan (connId msg)
        case mbChan of
          Nothing -> return () -- Drop it
          Just chan -> writeChan chan msg
  where
    handleResolve msg@(Connect {..}) chanId chan = case connHost of
      Left ipv4Addr -> handleConnect msg chanId chan ipv4Addr
      Right hostName -> do
        eiAddress <- try $ hostAddresses <$> getHostByName hostName
        case eiAddress of
          Left (e :: SomeException) -> do
            -- Cannot resolve host name
            writeLog $ "Cannot resolve hostname " ++
                       pprHostPort connHost connPort
            writeMsg (ConnectResult connId False Nothing)
            delChanById chanMan connId
          Right (ipv4Addr:_) -> handleConnect msg chanId chan ipv4Addr

    handleConnect (Connect {..}) chanId chan addr = do
      let sockAddr = SockAddrInet connPort addr
          hostPort = pprHostPort connHost connPort
      writeLog $ "Connecting to " ++ hostPort
      dstSock <- mkReusableSock
      connResult <- try (connect dstSock sockAddr)
      case connResult of
        Left (e :: IOException) -> do
          writeLog $ "Failed to connect to " ++ hostPort

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

          doCleanUp <- mkIdempotent reallyCleanUp

          let
            handleErr (e :: SomeException) = doCleanUp

          -- Read dst and write to local
          forkIO $ (`catchEx` handleErr) $ forever $ do
            someData <- hGetSome dstH 4096
            case B.null someData of
              True -> do
                writeLog $ "[doConnect] remote closed"
                doCleanUp
              False -> do
                let len = B.length someData
                writeLog $ "[doConnect] dst->local " ++ show len ++ " bytes"
                writeMsg (WriteTo chanId someData)

          -- Read local and write to dst
          forkIO $ (`catchEx` handleErr) $ forever $ do
            msg <- readChan chan
            case msg of
              WriteTo {..} -> do
                let len = B.length writeContent
                writeLog $ "[doConnect] local->dst " ++ show len ++ " bytes"
                B.hPut dstH writeContent
              Disconnect {..} -> do
                writeLog $ "[doConnect] local closed"
                doCleanUp

          return ()

