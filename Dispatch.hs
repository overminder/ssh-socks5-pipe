{-# LANGUAGE RecordWildCards #-}
module Dispatch where

import Control.Applicative
import Control.Exception
import Control.Concurrent
import Control.Monad
import qualified Data.Map as M
import Data.IORef
import qualified Data.ByteString as B
import System.IO
import Data.Serialize

import Message
import Compat

type ChanId = Int

data ChanManager a
  = ChanManager {
    manChanMap :: !(MVar (M.Map ChanId (Chan a))),
    manNextId :: !(MVar Int)
  }

mkChanManager = ChanManager <$> newMVar M.empty <*> newMVar 0

mkNewChan :: ChanManager a -> IO (ChanId, Chan a)
mkNewChan chanMan@(ChanManager {..}) =
  modifyMVar manNextId $ \ nextId -> do
    chan <- mkChanById chanMan nextId
    return (nextId + 1, (nextId, chan))

mkChanById :: ChanManager a -> ChanId -> IO (Chan a)
mkChanById (ChanManager {..}) chanId =
  modifyMVar manChanMap $ \ chanMap -> do
    chan <- newChan
    return (M.insert chanId chan chanMap, chan)

lookupChanById :: ChanManager a -> ChanId -> IO (Maybe (Chan a))
lookupChanById (ChanManager {..}) chanId = withMVar manChanMap $
  return . M.lookup chanId

delChanById :: ChanManager a -> ChanId -> IO ()
delChanById (ChanManager {..}) chanId
  = modifyMVar_ manChanMap $ return . M.delete chanId

-- Single-threaded message dispatcher
dispatchToChan :: Handle -> Chan Message -> IO ()
dispatchToChan h chan = dispatchToChan' h chan (runGetPartial get)

dispatchToChan' h chan parse = do
  newData <- hGetSome h 4096
  case B.null newData of
    False -> do
      let (msgs, parse') = go parse newData
      mapM_ (writeChan chan) msgs
      dispatchToChan' h chan parse'
    True ->
      throwIO $ userError "dispatchToChan: EOF"
  where
    go parse bs = case parse bs of
      Done msg rest ->
        let (msgs, parse') = go (runGetPartial get) rest
         in (msg:msgs, parse')
      Partial parse' -> ([], parse')
      Fail why -> error $ "parseMessage: " ++ why

dispatchFromChan :: Chan Message -> Handle -> IO ()
dispatchFromChan chan h = forever $ do
  msg <- readChan chan
  B.hPut h (encode msg)

