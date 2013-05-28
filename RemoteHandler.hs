{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

module Main where

import Control.Applicative
import Control.Concurrent
import Control.Monad
import Control.Monad.Trans
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

type TryCatch a = IO (Either SomeException a)

wLog mbH lock s = do
  let toPrint = "[Remote] " ++ s
  withMVar lock $ \ () -> do
    maybe (return ()) (`hPutStrLn` toPrint) mbH
    try (hPutStrLn stderr $ "[Remote] " ++ s) :: TryCatch ()
    return ()

main = do
  logLock <- newMVar ()
  eiLogFile <- try (openFile "/tmp/remote.log" WriteMode) :: TryCatch Handle
  let mbLogFile = either (const Nothing) Just eiLogFile
  maybe (return ()) (`hSetBuffering` NoBuffering) mbLogFile
  let writeLog = wLog mbLogFile logLock

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

mkStdIOTransport :: (String -> IO ()) -> (IO () -> IO ()) ->
                    IO (ReadMsg, WriteMsg)
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

