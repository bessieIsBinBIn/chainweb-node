{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- |
-- Module: Chainweb.CutDB
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.CutDB
(
-- * CutConfig
  CutDbConfig(..)
, cutDbConfigInitialCut
, cutDbConfigInitialCutFile
, cutDbConfigBufferSize
, cutDbConfigLogLevel
, cutDbConfigTelemetryLevel
, defaultCutDbConfig

-- * CutHashes
, CutHashes(..)
, cutToCutHashes

-- * CutDb
, CutDb
, cutDbWebBlockHeaderDb
, cut
, _cut
, _cutStm
, cutStm
, cutStream
, addCutHashes
, withCutDb
, startCutDb
, stopCutDb

-- * Some CutDb
, CutDbT(..)
, SomeCutDb(..)
, someCutDbVal
) where

import Control.Concurrent.Async
import Control.Concurrent.STM.TBQueue
import Control.Concurrent.STM.TVar
import Control.DeepSeq
import Control.Exception
import Control.Lens hiding ((:>))
import Control.Monad hiding (join)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class
import Control.Monad.STM

import Data.Aeson
import Data.Foldable
import Data.Function
import Data.Functor.Of
import Data.Hashable
import qualified Data.HashMap.Strict as HM
import Data.Maybe
import Data.Monoid
import Data.Ord
import Data.Reflection hiding (int)

import GHC.Generics hiding (to)

import Numeric.Natural

import Prelude hiding (lookup)

import qualified Streaming.Prelude as S

import System.LogLevel

-- internal modules

import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.ChainId
import Chainweb.Cut
import Chainweb.Graph
import Chainweb.TreeDB
import Chainweb.Utils hiding (check)
import Chainweb.Version
import Chainweb.WebBlockHeaderDB

import Data.Singletons

import P2P.Peer

-- -------------------------------------------------------------------------- --
-- Cut DB Configuration

data CutDbConfig = CutDbConfig
    { _cutDbConfigInitialCut :: !Cut
    , _cutDbConfigInitialCutFile :: !(Maybe FilePath)
    , _cutDbConfigBufferSize :: !Natural
    , _cutDbConfigLogLevel :: !LogLevel
    , _cutDbConfigTelemetryLevel :: !LogLevel
    }
    deriving (Show, Eq, Ord, Generic)

makeLenses ''CutDbConfig

defaultCutDbConfig :: ChainwebVersion -> ChainGraph -> CutDbConfig
defaultCutDbConfig v g = CutDbConfig
    { _cutDbConfigInitialCut = genesisCut_ g v
    , _cutDbConfigInitialCutFile = Nothing
    , _cutDbConfigBufferSize = 10
        -- FIXME this should probably depend on the diameter of the graph
    , _cutDbConfigLogLevel = Warn
    , _cutDbConfigTelemetryLevel = Warn
    }

-- -------------------------------------------------------------------------- --
-- Cut Hashes

data CutHashes = CutHashes
    { _cutHashes :: !(HM.HashMap ChainId BlockHash)
    , _cutOrigin :: !(Maybe PeerInfo)
        -- ^ 'Nothing' is used for locally minded Cuts
    }
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (Hashable)

instance ToJSON CutHashes
instance FromJSON CutHashes
instance NFData CutHashes

cutToCutHashes :: Maybe PeerInfo -> Cut -> CutHashes
cutToCutHashes p c = CutHashes (_blockHash <$> _cutMap c) p

-- -------------------------------------------------------------------------- --
-- Cut DB

-- | This is a singleton DB that contains the latest chainweb cut as only
-- entry.
--
data CutDb = CutDb
    { _cutDbCut :: !(TVar Cut)
    , _cutDbQueue :: !(TBQueue CutHashes)
        -- FIXME: TBQueue is a poor choice in applications that require low
        -- latencies (internally, it uses the classic function queue
        -- implementation with two stacks that has a performance distribution
        -- with a very long tail.)
        --
        -- TODO use a priority queue, that prioritizes heavier cuts and newer
        -- cuts. It should also be non-blocking but instead discard older
        -- entries. We may use the streaming-concurrency package for that.
        --
        -- For now we treat all peers equal. A local miner is just another peer
        -- that provides new cuts.

    , _cutDbWebBlockHeaderDb :: !WebBlockHeaderDb
    , _cutDbAsync :: !(Async ())
    }

instance HasChainGraph CutDb where
    _chainGraph = _chainGraph . _cutDbWebBlockHeaderDb
    {-# INLINE _chainGraph #-}

-- We export the 'WebBlockHeaderDb' read-only
--
cutDbWebBlockHeaderDb :: Getter CutDb WebBlockHeaderDb
cutDbWebBlockHeaderDb = to _cutDbWebBlockHeaderDb

-- | Get the current 'Cut', which represent the latest chainweb state.
--
-- This the main API method of chainweb-consensus.
--
_cut :: CutDb -> IO Cut
_cut = readTVarIO . _cutDbCut

-- | Get the current 'Cut', which represent the latest chainweb state.
--
-- This the main API method of chainweb-consensus.
--
cut :: Getter CutDb (IO Cut)
cut = to _cut

addCutHashes :: CutDb -> CutHashes -> STM ()
addCutHashes db = writeTBQueue (_cutDbQueue db)

-- | An 'STM' version of '_cut'.
--
-- @_cut db@ is generally more efficient than as @atomically (_cut db)@.
--
_cutStm :: CutDb -> STM Cut
_cutStm = readTVar . _cutDbCut

-- | An 'STM' version of 'cut'.
--
-- @_cut db@ is generally more efficient than as @atomically (_cut db)@.
--
cutStm :: Getter CutDb (STM Cut)
cutStm = to _cutStm

withCutDb :: CutDbConfig -> WebBlockHeaderDb -> (CutDb -> IO a) -> IO a
withCutDb config wdb = bracket (startCutDb config wdb) stopCutDb

startCutDb :: CutDbConfig -> WebBlockHeaderDb -> IO CutDb
startCutDb config wdb = mask_ $ do
    cutVar <- newTVarIO (_cutDbConfigInitialCut config)
    queue <- newTBQueueIO (int $ _cutDbConfigBufferSize config)
    CutDb cutVar queue wdb
        <$> give wdb (asyncWithUnmask $ \u -> u (processCuts queue cutVar))

stopCutDb :: CutDb -> IO ()
stopCutDb db = cancel (_cutDbAsync db)

-- | This is at the heart of 'Chainweb' POW: Deciding the current "longest" cut
-- among the incoming candiates.
--
-- Going forward this should probably be the main scheduler for most operations,
-- in particular it should drive (or least preempt) synchronzations of block
-- headers on indiviual chains.
--
processCuts
    :: Given WebBlockHeaderDb
    => TBQueue CutHashes
    -> TVar Cut
    -> IO ()
processCuts queue cutVar = queueToStream
    & S.mapM cutHashesToBlockHeaderMap
    & S.concat
        -- ignore left values for now
    & S.scanM
        (\a b -> joinIntoHeavier_ (_cutMap a) b)
        (readTVarIO cutVar)
        (atomically . writeTVar cutVar)
    & S.effects
  where
    queueToStream =
        liftIO (atomically $ readTBQueue queue) >>= S.yield >> queueToStream

-- | Stream of most recent cuts. This stream does not generally include the full
-- history of cuts. When no cuts are demanded from the stream or new cuts are
-- produced faster than they are consumed from the stream, the stream skips over
-- cuts and always returns the latest cut in the db.
--
cutStream :: MonadIO m => CutDb -> S.Stream (Of Cut) m r
cutStream db = liftIO (_cut db) >>= \c -> S.yield c >> go c
  where
    go cur = do
        new <- liftIO $ atomically $ do
            c' <- _cutStm db
            check (c' /= cur)
            return c'
        S.yield new
        go new

cutHashesToBlockHeaderMap
    :: Given WebBlockHeaderDb
    => CutHashes
    -> IO (Either (HM.HashMap ChainId BlockHash) (HM.HashMap ChainId BlockHeader))
        -- ^ The 'Left' value holds missing hashes, the 'Right' value holds
        -- a 'Cut'.
cutHashesToBlockHeaderMap hs = do
    (headers :> missing) <- S.each (HM.toList $ _cutHashes hs)
        & S.mapM tryLookup
        & S.partitionEithers
        & S.fold_ (\x (cid, h) -> HM.insert cid h x) mempty id
        & S.fold (\x (cid, h) -> HM.insert cid h x) mempty id
    if null missing
        then return $ Right headers
        else return $ Left missing
  where
    tryLookup (cid, h) =
        (Right <$> mapM lookupWebBlockHeaderDb (cid, h)) `catch` \case
            (TreeDbKeyNotFound{} :: TreeDbException BlockHeaderDb) ->
                return $ Left (cid, h)
            e ->
                throwM e

-- -------------------------------------------------------------------------- --
-- Some CutDB

-- | 'CutDb' with type level 'ChainwebVersion'
--
newtype CutDbT (v :: ChainwebVersionT) = CutDbT CutDb
    deriving (Generic)

data SomeCutDb = forall v . KnownChainwebVersionSymbol v => SomeCutDb (CutDbT v)

someCutDbVal :: ChainwebVersion -> CutDb -> SomeCutDb
someCutDbVal (FromSing (SChainwebVersion :: Sing v)) db = SomeCutDb $ CutDbT @v db
