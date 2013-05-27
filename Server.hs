{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

import Control.Applicative
import Control.Monad
import Control.Concurrent
import Control.Monad.Reader
import Control.Exception
import qualified Data.ByteString as B
import System.Environment
import System.IO
import System.Info
import System.Process
import Network.Socket
import Network.BSD

import Dispatch
import Protocol
import Message
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
      (rMsg, wMsg) <- mkSshTransport user host 22 remotePath
      chanMan <- mkChanManager
      runProtocol (ProtocolState fwdOpt rMsg wMsg writeLog chanMan) runLocalPart
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
        [port1, host, port2] = split ':' fwdArg

    mkPortNum :: Int -> PortNumber
    mkPortNum = fromIntegral

mkSshTransport :: String -> String -> Int -> String -> IO (ReadMsg, WriteMsg)
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

runLocalPart = do
  writeMsg <- asks protoWriteMsg
  fwdOpt <- asks protoFwdOpt

  liftIO $ writeMsg (HandShake fwdOpt)
  case fwdOpt of
    FwdLocal {..}         -> runLocalServer handleLocalFwdReq
    FwdLocalDynamic {..}  -> runLocalServer handleSocks5ClientReq
    FwdRemote {..}        -> runPortForwarder
    FwdRemoteDynamic {..} -> runPortForwarder

