{-# LANGUAGE CPP #-}
module UnitTests.Distribution.Utils.Structured (tests) where

import Data.Proxy                    (Proxy (..))
import Distribution.Utils.MD5        (md5FromInteger)
import Distribution.Utils.Structured (structureHash)
import Test.Tasty                    (TestTree, testGroup)
import Test.Tasty.HUnit              (testCase, (@?=))

import Distribution.SPDX.License       (License)
import Distribution.Types.VersionRange (VersionRange)

#if MIN_VERSION_base(4,7,0)
import Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import Distribution.Types.LocalBuildInfo            (LocalBuildInfo)
#endif

import UnitTests.Orphans ()

tests :: TestTree
tests = testGroup "Distribution.Utils.Structured"
    -- This test also verifies that structureHash doesn't loop.
    [ testCase "VersionRange"              $ structureHash (Proxy :: Proxy VersionRange)               @?= md5FromInteger 0x39396fc4f2d751aaa1f94e6d843f03bd
    , testCase "SPDX.License"              $ structureHash (Proxy :: Proxy License)                    @?= md5FromInteger 0xd3d4a09f517f9f75bc3d16370d5a853a
    -- The difference is in encoding of newtypes
#if MIN_VERSION_base(4,7,0)
    , testCase "GenericPackageDescription" $ structureHash (Proxy :: Proxy GenericPackageDescription)  @?= md5FromInteger 0xf3a898a586312623fe123876e53f346c
    , testCase "LocalBuildInfo"            $ structureHash (Proxy :: Proxy LocalBuildInfo)             @?= md5FromInteger 0xeff1b7556bd8b832eae5bd8d8a33019c
#endif
    ]
