module MessageTest where

import Control.Applicative
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Binary
import Test.QuickCheck

import Message

instance Arbitrary B.ByteString where
  arbitrary = B.pack <$> arbitrary

instance Arbitrary Message where
  arbitrary = do
    msgKind <- elements [0..3]
    msgId <- arbitrary
    case msgKind of
      0 -> Connect msgId <$> arbitrary <*> arbitrary
      1 -> ConnectResult msgId <$> arbitrary <*> arbitrary
      2 -> WriteTo msgId <$> arbitrary
      3 -> pure $ Disconnect msgId

propSingleCodec :: Message -> Property
propSingleCodec msg = property $ msg' == msg
  where
    msg' = decode . encode $ msg

propSingleSerialize :: Message -> Property
propSingleSerialize msg = property $
  msg' == msg && BL.null rest
  where
    (rest, [msg']) = deserialize . serialize $ msg

propChunkedSerialize :: [Message] -> Property
propChunkedSerialize msgs = property $
  msgs == msgs' && BL.null bs2Rest
  where
    bs = BL.concat (map serialize msgs)
    bsLen = BL.length bs
    (bs1, bs2) = BL.splitAt (bsLen `div` 2) bs
    (bs1Rest, msgs1) = deserialize bs1
    (bs2Rest, msgs2) = deserialize $ bs1Rest `BL.append` bs2
    msgs' = msgs1 ++ msgs2

