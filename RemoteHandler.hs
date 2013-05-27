{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

import Control.Applicative
import Control.Concurrent
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.ByteString as B
import Network.Socket
import Network.BSD
import System.IO
import System.Exit
import Control.Exception

import Dispatch
import Message
import Compat
import Protocol

wLog h lock s = do
  withMVar lock $ \ () -> do
    hPutStrLn h $ "[Remote] " ++ s
    try (hPutStrLn stderr $ "[Remote] " ++ s) :: IO (Either SomeException ())
    return ()

main = do
  logLock <- newMVar ()
  logFile <- openFile "/tmp/remote.log" WriteMode
  hSetBuffering logFile NoBuffering
  let writeLog = wLog logFile logLock

  waitForCallable $ \ putCallable -> forkIO $ do
    (rMsg, wMsg) <- mkStdIOTransport writeLog putCallable
    -- First message: tells about forward mode.
    (HandShake fwdOpt) <- rMsg
    writeLog (show fwdOpt)
    chanMan <- mkChanManager

    let protoState = ProtocolState fwdOpt rMsg wMsg writeLog chanMan

    runProtocol protoState $ case fwdOpt of
      FwdLocal {..}         -> runPortForwarder
      FwdLocalDynamic {..}  -> runPortForwarder
      FwdRemote {..}        -> runLocalServer handleLocalFwdReq
      FwdRemoteDynamic {..} -> runLocalServer handleSocks5ClientReq

waitForCallable m = do
  ref <- newEmptyMVar
  let
    callRef = do
      f <- takeMVar ref
      f
  m (putMVar ref)
  callRef

mkStdIOTransport :: (String -> IO ()) -> (IO () -> IO ()) -> IO (ReadMsg, WriteMsg)
mkStdIOTransport wLog callInMain = do
  forM_ [stdin, stdout] $ \ h -> do
    hSetBuffering h NoBuffering
    hSetBinaryMode h True

  rChan <- newChan
  wChan <- newChan

  let
    handleErr (e :: SomeException) = do
      wLog $ "stdin/out got EOF: exiting"
      callInMain $ exitWith ExitSuccess

  forkIO $ (`catchEx` handleErr) $ dispatchToChan stdin rChan
  forkIO $ (`catchEx` handleErr) $ dispatchFromChan wChan stdout

  return (readChan rChan, writeChan wChan)

