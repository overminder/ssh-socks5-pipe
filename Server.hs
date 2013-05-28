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
import System.Exit
import System.Process
import Network.Socket
import Network.BSD

import Dispatch
import Protocol
import Message
import Compat

wLog lock s = do
  withMVar lock $ \ () -> hPutStrLn stderr $ "[Server] " ++ s
wLogB lock bs = do
  withMVar lock $ \ () -> B.hPut stderr bs

main = do
  args <- getArgs
  case args of
    [user, host, remotePath, fwdType, fwdArg] -> do
      logLock <- newMVar ()
      let fwdOpt = parseFwdOpt fwdType fwdArg
          writeLog = wLog logLock
          writeLogB = wLogB logLock
      writeLog (show fwdOpt)
      waitForCallable $ \ callInMain -> forkIO $ do
        (rMsg, wMsg, sshErr) <- mkSshTransport user host 22
                                remotePath callInMain
        chanMan <- mkChanManager

        forkIO $ forever $ do
          debugMsg <- hGetSome sshErr 4096
          case B.null debugMsg of
            True -> throwIO $ userError "sshErr got EOF"
            False -> writeLogB debugMsg

        let protoState = ProtocolState fwdOpt rMsg wMsg writeLog chanMan
        runProtocol protoState runLocalPart
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

mkSshTransport :: String -> String -> Int -> String -> (IO () -> IO ()) ->
                  IO (ReadMsg, WriteMsg, Handle)
mkSshTransport user host port command callInMain = do
  (Just sshIn, Just sshOut, Just sshErr, _) <- createProcess $
    sshProc { std_in = CreatePipe, std_out = CreatePipe
            , std_err = CreatePipe }

  forM_ [sshIn, sshOut, sshErr] $ \ h -> do
    hSetBuffering h NoBuffering
    hSetBinaryMode h True

  rChan <- newChan
  wChan <- newChan

  let
    handleErr (e :: SomeException) = do
      callInMain $ exitSuccess

  forkIO $ (`catchEx` handleErr) $ dispatchToChan sshOut rChan
  forkIO $ (`catchEx` handleErr) $ dispatchFromChan wChan sshIn

  -- SSH connection established.
  return (readChan rChan, writeChan wChan, sshErr)
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

