{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE OverloadedStrings    #-}

{-# OPTIONS_GHC -Werror -Wall     #-}

module TypesSpec where

import Data.Set.Lens (setOf)
import Data.Data.Lens (template)
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)
import Test.QuickCheck (property)

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Set as Set

import Arbitrary (schoolClasses)
import AulaTests (tag, TestSuite(..))
import AulaPrelude
import Persistent.Pure
import Types

renameInData :: Data a => (ClassName -> ClassName) -> a -> a
renameInData = over $ template . className

spec :: Spec
spec = do
    describe "Timestamp" $ do
        it "read and show are inverses" . property $
            \x -> read (show x) == (x :: Timestamp)
        it "parseTimestamp and showTimestamp are inverses" . property $
            isJust . parseTimestamp . showTimestamp
        it "parseTimestamp should fail on noise" . property $
            isNothing . parseTimestamp . (<> "noise") . showTimestamp

    describe "Timespan" $ do
        it "aeson encode and decode are inverses" . property $
            \(x :: Timespan) ->
                  -- because historically, there has been a distinction between top-level values
                  -- (arrays and objects), and internal values (also literals like strings), and
                  -- because we depend on a rather old aeson version, we work on an object in this
                  -- test.
                  let x' = Aeson.object ["value" Aeson..= x]
                  in Aeson.decode (Aeson.encode x') == Just x'

    describe "diffTimestamps(-), addTimespan(+)" $ do
        it "(y+x)-x = y" . property $
            \(x :: Timestamp) (y :: Timespan) ->
                timespanUs ((y `addTimespan` x) `diffTimestamps` x) `shouldBe` timespanUs y
        it "y-((y-x)+x) = 0" . property $
            \(x :: Timestamp) (y :: Timestamp) ->
                timespanUs (y `diffTimestamps` ((y `diffTimestamps` x) `addTimespan` x)) `shouldBe` 0

    tag Large $ do
        describe "DelegationNetwork" $ do
            it "generates" . property $
                \(dn :: DelegationNetwork) -> length (show dn) `shouldNotBe` 0
            it "aeson-encodes" . property $
                \(dn :: DelegationNetwork) -> LBS.length (Aeson.encode dn) `shouldNotBe` 0

    describe "Fixing AulaData" $ do
        it "is should not remove any Timestamp value" . property $ \d ->
            let d' = fixAulaData d
                len = lengthOf (template :: Traversal' AulaData Timestamp) in
            len d' `shouldBe` len d

        it "is idempotent" . property $ \d ->
            let d' = fixAulaData d in
            fixAulaData d' `shouldBe` d'

    describe "Renaming classes" $ do
        it "works" . property $ \(d :: AulaData) ->
            let f cl = cl & unClassName <>~ "TEST" in
            renameInAulaData f d `shouldBe` renameInData f d

    describe "Destroying classes" $ do
        it "does nothing when the class does not exist" . property $ \(d :: AulaData) ->
            destroyClassPure (SchoolClass 0 (ClassName "DOES NOT EXIST")) d `shouldBe` d

        it "does nothing when any class matches" . property $ \(d :: AulaData) ->
            filterClasses (const True) d `shouldBe` d

        it "removes any occurrence of this class" . property $ \(d' :: AulaData) clss ->
            let d = d' & dbSpaceSet .~ Set.fromList (ClassSpace <$> schoolClasses)
                       & fixAulaData
                classNames = setOf (template . unClassName) in
            classNames (destroyClassPure clss d)
                `shouldBe`
            ((clss ^. className . unClassName) `Set.delete` classNames d)
