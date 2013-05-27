{-# LANGUAGE RecordWildCards, OverloadedStrings, ScopedTypeVariables #-}

import Control.Applicative
import Control.Concurrent
import Control.Monad.Reader
import qualified Data.Map as M
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Network.Socket
import Network.BSD
import System.IO
import System.Exit
import Control.Exception

import Message
import Compat

data ConnState
  = ConnState {
    connSockets :: !(MVar (M.Map Int (Socket, Handle))),
    connWriteMsg :: !(Message -> IO ()),
    connChannels :: !(MVar (M.Map Int (Chan Message))),
    connWriteLog :: !(String -> IO ()),
    connRemoveChan :: !(Int -> IO ())
  }

type ConnM = ReaderT ConnState IO

logFilePath = "/home/overmind/src/haskell/conch-proxy/remote.log"

main = do
  writeLock <- newMVar ()
  readBuf <- newIORef B.empty
  sockMap <- newMVar M.empty
  chanRef <- newMVar M.empty
  logFile <- openFile logFilePath WriteMode
  logLock <- newMVar ()

  mapM_ (`hSetBuffering` NoBuffering) [stdin, stdout, logFile]

  let
    writeMessage msg = do
      --writeLog $ "[writeMsg] " ++ show msg
      withMVar writeLock $ \ () -> do
        BL.hPut stdout $ serialize msg

    writeLog s = withMVar logLock $ \ () -> hPutStrLn logFile s

    removeChan chanId = modifyMVar_ chanRef $ \ chanMap -> do
      writeLog $ "[removeChan] id=" ++ show chanId ++ ", totalChan=" ++
                 show (M.size chanMap - 1)
      return (M.delete chanId chanMap)

    initState = ConnState {
      connSockets = sockMap,
      connWriteMsg = writeMessage,
      connChannels = chanRef,
      connWriteLog = writeLog,
      connRemoveChan = removeChan
    }

  writeLog "[main] startup"
  forever $ do
    newData <- hGetSome stdin 4096
    case B.length newData of
      0 -> do
        writeLog "[main] shutdown"
        exitWith ExitSuccess
      _ -> do
        oldData <- readIORef readBuf
        let (rest, msgs) = deserialize (toLazy (oldData `B.append` newData))
        writeIORef readBuf (toStrict rest)
        forkIO $ runReaderT (mapM_ handleMsg msgs) initState

handleMsg :: Message -> ConnM ()
handleMsg msg = do
  writeLog <- asks connWriteLog
  let chanId = connId msg
  --liftIO $ writeLog $ "[handleMsg] Got message " ++ show msg

  connState <- ask
  chanRef <- asks connChannels
  liftIO $ modifyMVar_ chanRef $ \ chanMap -> do
    let mbChan = M.lookup chanId chanMap
    case mbChan of
      Nothing | isConnect msg -> do
        writeLog $ "[handleMsg] Create chan for id=" ++ show chanId ++
                   ", totalChan=" ++ show (1 + M.size chanMap)
        chan <- newChan
        forkIO $ runReaderT (doConnect chanId chan msg) connState
        return $ M.insert chanId chan chanMap
      Nothing -> do
        writeLog $ "[handleMsg] Drop msg for close chan id=" ++ show chanId
        return chanMap
      Just chan -> do
        writeLog $ "[handleMsg] Write to existing chan id=" ++ show chanId
        writeChan chan msg
        return chanMap

doConnect :: Int -> Chan Message -> Message -> ConnM ()
doConnect chanId chan (Connect {..}) = do
  writeLog <- asks connWriteLog
  writeMsg <- asks connWriteMsg
  removeChan <- asks connRemoveChan
  ipv4Addr <- case connHost of
    Left ipv4Addr -> return (fromIntegral ipv4Addr)
    Right hostName -> do
      (ipv4Addr:_) <- liftIO $ hostAddresses <$> getHostByName hostName
      return ipv4Addr
  let sockAddr = SockAddrInet (fromIntegral connPort) ipv4Addr
      showHostPort = show connHost ++ ":" ++ show connPort

  liftIO $ do
    writeLog $ "[doConnect] Connecting " ++ showHostPort
    dstSock <- mkReusableSock
    connResult <- try (connect dstSock sockAddr)
    case connResult of
      Left (e :: IOException) -> do
        writeLog $ "[doConnect] Failed to connect to " ++ showHostPort
        writeMsg (ConnectResult connId False Nothing)
        removeChan chanId
      Right _ -> do
        writeLog $ "[doConnect] Successfully connected to " ++ showHostPort
        dstHandle <- socketToHandle dstSock ReadWriteMode
        hSetBuffering dstHandle NoBuffering
        SockAddrInet portUsed addrUsed <- getSocketName dstSock
        -- Connection opened
        writeMsg (ConnectResult connId True
                                (Just (fromIntegral addrUsed,
                                       fromIntegral portUsed)))
        let
          reallyCleanUp = do
            writeLog $ "[cleanUp] Done for id=" ++ show chanId
            writeMsg (Disconnect chanId)
            shutdown dstSock ShutdownBoth
            hClose dstHandle
            removeChan chanId

        cleanUpVar <- newMVar reallyCleanUp

        let
          cleanUp' = do
            todo <- swapMVar cleanUpVar (return ())
            todo

          cleanUp (e :: IOException) = cleanUp'

        -- Read dst and write to local
        forkIO $ (`Control.Exception.catch` cleanUp) $ forever $ do
          someData <- hGetSome dstHandle 4096
          case B.length someData of
            0 -> do
              writeLog $ "[doConnect] remote closed"
              cleanUp'
            len -> do
              writeLog $ "[doConnect] dst->local " ++ show len ++ " bytes"
              writeMsg (WriteTo chanId someData)

        -- Read local and write to dst
        forkIO $ (`Control.Exception.catch` cleanUp) $ forever $ do
          msg <- readChan chan
          case msg of
            WriteTo {..} -> do
              let len = B.length writeContent
              writeLog $ "[doConnect] local->dst " ++ show len ++ " bytes"
              B.hPut dstHandle writeContent
            Disconnect {..} -> do
              writeLog $ "[doConnect] local closed"
              cleanUp'

        return ()

