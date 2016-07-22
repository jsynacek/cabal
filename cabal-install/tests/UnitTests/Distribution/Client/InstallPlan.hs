module UnitTests.Distribution.Client.InstallPlan (tests) where

import           Distribution.Package
import           Distribution.Version
import qualified Distribution.Client.InstallPlan as InstallPlan
import           Distribution.Client.InstallPlan (GenericInstallPlan)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import           Distribution.Solver.Types.Settings
import           Distribution.Solver.Types.PackageFixedDeps
import           Distribution.Solver.Types.ComponentDeps as CD
import           Distribution.Text

import Data.Graph
import Data.Array hiding (index)
import Data.List
import qualified Data.Map as Map
import Control.Monad
import Test.QuickCheck

import Test.Tasty
import Test.Tasty.QuickCheck


tests :: [TestTree]
tests =
  [ testProperty "topologicalOrder"        prop_topologicalOrder
  , testProperty "reverseTopologicalOrder" prop_reverseTopologicalOrder
  ]

prop_topologicalOrder :: TestInstallPlan -> Bool
prop_topologicalOrder (TestInstallPlan plan graph toVertex _) =
    isTopologicalOrder
      graph
      (map (toVertex . installedUnitId)
           (InstallPlan.topologicalOrder plan))

prop_reverseTopologicalOrder :: TestInstallPlan -> Bool
prop_reverseTopologicalOrder (TestInstallPlan plan graph toVertex _) =
    isReverseTopologicalOrder
      graph
      (map (toVertex . installedUnitId)
           (InstallPlan.reverseTopologicalOrder plan))


--------------------------
-- Property helper utils
--

-- | A graph topological ordering is a linear ordering of its vertices such
-- that for every directed edge uv from vertex u to vertex v, u comes before v
-- in the ordering.
--
isTopologicalOrder :: Graph -> [Vertex] -> Bool
isTopologicalOrder g vs =
    and [ ixs ! u < ixs ! v
        | let ixs = array (bounds g) (zip vs [0::Int ..])
        , (u,v) <- edges g ]

isReverseTopologicalOrder :: Graph -> [Vertex] -> Bool
isReverseTopologicalOrder g vs =
    and [ ixs ! u > ixs ! v
        | let ixs = array (bounds g) (zip vs [0::Int ..])
        , (u,v) <- edges g ]


--------------------
-- Test generators
--

data TestInstallPlan = TestInstallPlan
                         (GenericInstallPlan TestPkg TestPkg () ())
                         Graph
                         (UnitId -> Vertex)
                         (Vertex -> UnitId)

instance Show TestInstallPlan where
  show (TestInstallPlan plan _ _ _) = InstallPlan.showInstallPlan plan

data TestPkg = TestPkg PackageId UnitId [UnitId]
  deriving (Eq, Show)

instance Package TestPkg where
  packageId (TestPkg pkgid _ _) = pkgid

instance HasUnitId TestPkg where
  installedUnitId (TestPkg _ ipkgid _) = ipkgid

instance PackageFixedDeps TestPkg where
  depends (TestPkg pkgid _ deps) =
    CD.singleton (CD.ComponentLib (display (packageName pkgid))) deps

instance Arbitrary TestInstallPlan where
  arbitrary = arbitraryTestInstallPlan

arbitraryTestInstallPlan :: Gen TestInstallPlan
arbitraryTestInstallPlan = do
    graph <- arbitraryAcyclicGraph
               (choose (2,5))
               (choose (1,5))
               0.3

    plan  <- arbitraryInstallPlan mkTestPkg mkTestPkg 0.5 graph

    let toVertexMap   = Map.fromList [ (mkUnitIdV v, v) | v <- vertices graph ]
        fromVertexMap = Map.fromList [ (v, mkUnitIdV v) | v <- vertices graph ]
        toVertex      = (toVertexMap   Map.!)
        fromVertex    = (fromVertexMap Map.!)

    return (TestInstallPlan plan graph toVertex fromVertex)
  where
    mkTestPkg pkgv depvs =
        return (TestPkg pkgid ipkgid deps)
      where
        pkgid  = mkPkgId pkgv
        ipkgid = mkUnitIdV pkgv
        deps   = map mkUnitIdV depvs
    mkUnitIdV = mkUnitId . show
    mkPkgId v = PackageIdentifier (PackageName ("pkg" ++ show v))
                                  (Version [1] [])


-- | Generate a random 'InstallPlan' following the structure of an existing
-- 'Graph'.
--
-- It takes generators for installed and source packages and the chance that
-- each package is installed (for those packages with no prerequisites).
--
arbitraryInstallPlan :: (HasUnitId ipkg,   PackageFixedDeps ipkg,
                         HasUnitId srcpkg, PackageFixedDeps srcpkg)
                     => (Vertex -> [Vertex] -> Gen ipkg)
                     -> (Vertex -> [Vertex] -> Gen srcpkg)
                     -> Float
                     -> Graph
                     -> Gen (InstallPlan.GenericInstallPlan ipkg srcpkg () ())
arbitraryInstallPlan mkIPkg mkSrcPkg ipkgProportion graph = do

    (ipkgvs, srcpkgvs) <-
      fmap ((\(ipkgs, srcpkgs) -> (map fst ipkgs, map fst srcpkgs))
            . partition snd) $
      sequence
        [ do isipkg <- if isRoot then pick ipkgProportion
                                 else return False
             return (v, isipkg)
        | (v,n) <- assocs (outdegree graph)
        , let isRoot = n == 0 ]

    ipkgs   <- sequence
                 [ mkIPkg pkgv depvs
                 | pkgv <- ipkgvs
                 , let depvs  = graph ! pkgv
                 ]
    srcpkgs <- sequence
                 [ mkSrcPkg pkgv depvs
                 | pkgv <- srcpkgvs
                 , let depvs  = graph ! pkgv
                 ]
    let index = PackageIndex.fromList (map InstallPlan.PreExisting ipkgs
                                    ++ map InstallPlan.Configured  srcpkgs)
    case InstallPlan.new (IndependentGoals False) index of
      Right plan -> return plan
      Left  problems -> fail $ unlines $
                          map InstallPlan.showPlanProblem problems


-- | Generate a random directed acyclic graph, based on the algorithm presented
-- here <http://stackoverflow.com/questions/12790337/generating-a-random-dag>
--
-- It generates a DAG based on ranks of nodes. Nodes in each rank can only
-- have edges to nodes in subsequent ranks.
--
-- The generator is paramterised by a generator for the number of ranks and
-- the number of nodes within each rank. It is also paramterised by the
-- chance that each node in each rank will have an edge from each node in
-- each previous rank. Thus a higher chance will produce a more densely
-- connected graph.
--
arbitraryAcyclicGraph :: Gen Int -> Gen Int -> Float -> Gen Graph
arbitraryAcyclicGraph genNRanks genNPerRank edgeChance = do
    nranks    <- genNRanks
    rankSizes <- replicateM nranks genNPerRank
    let rankStarts = scanl (+) 0 rankSizes
        rankRanges = drop 1 (zip rankStarts (tail rankStarts))
        totalRange = sum rankSizes
    rankEdges <- mapM (uncurry genRank) rankRanges
    return $ buildG (0, totalRange-1) (concat rankEdges)
  where
    genRank :: Vertex -> Vertex -> Gen [Edge]
    genRank rankStart rankEnd =
      filterM (const (pick edgeChance))
        [ (i,j)
        | i <- [0..rankStart-1]
        , j <- [rankStart..rankEnd-1]
        ]

pick :: Float -> Gen Bool
pick chance = do
    p <- choose (0,1)
    return (p < chance)


--------------------------------
-- Inspecting generated graphs
--

{-
-- Handy util for checking the generated graphs look sensible
writeDotFile :: FilePath -> Graph -> IO ()
writeDotFile file = writeFile file . renderDotGraph

renderDotGraph :: Graph -> String
renderDotGraph graph =
  unlines (
      [header
      ,graphDefaultAtribs
      ,nodeDefaultAtribs
      ,edgeDefaultAtribs]
    ++ map renderNode (vertices graph)
    ++ map renderEdge (edges graph)
    ++ [footer]
  )
  where
    renderNode n = "\t" ++ show n ++ " [label=\"" ++ show n ++  "\"];"

    renderEdge (n, n') = "\t" ++ show n ++ " -> " ++ show n' ++ "[];"


header, footer, graphDefaultAtribs, nodeDefaultAtribs, edgeDefaultAtribs :: String

header = "digraph packages {"
footer = "}"

graphDefaultAtribs = "\tgraph [fontsize=14, fontcolor=black, color=black];"
nodeDefaultAtribs  = "\tnode [label=\"\\N\", width=\"0.75\", shape=ellipse];"
edgeDefaultAtribs  = "\tedge [fontsize=10];"
-}
