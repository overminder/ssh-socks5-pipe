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
import Message
import Compat
import Protocol

wLog lock s = do
  withMVar lock $ \ () -> hPutStrLn stderr $ "[Remote] " ++ s

main = do
  logLock <- newMVar ()
  (rMsg, wMsg) <- mkStdIOTransport
  (HandShake fwdOpt) <- rMsg
  let writeLog = wLog logLock
  writeLog (show fwdOpt)
  chanMan <- mkChanManager

  case fwdOpt of
    FwdLocalDynamic {..} ->
      runProtocol (ProtocolState fwdOpt rMsg wMsg writeLog chanMan)
                  runPortForwarder
    _ -> writeLog $ "not supported yet: " ++ show fwdOpt

mkStdIOTransport :: IO (ReadMsg, WriteMsg)
mkStdIOTransport = do
  forM_ [stdin, stdout] $ \ h -> do
    hSetBuffering h NoBuffering
    hSetBinaryMode h True

  rChan <- newChan
  wChan <- newChan

  forkIO $ dispatchToChan stdin rChan
  forkIO $ dispatchFromChan wChan stdout

  return (readChan rChan, writeChan wChan)

