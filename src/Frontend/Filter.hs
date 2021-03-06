{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module Frontend.Filter
    ( Filter(Filtered, applyFilter, renderFilter)
    , SearchTerm(..), unSearchTerm

    , IdeasFilterQuery(..), _AllIdeas, _IdeasWithCat, catFilter
    , SortIdeasBy(..)
    , IdeasQuery(..), mkIdeasQuery, ideasQueryF, ideasQueryS, ideasQueryT, emptyIdeasQuery
    , IdeasQueryApi
    , toggleIdeasFilter

    , SearchUsers(..), UsersFilterQuery(..)
    , _AllUsers, _UsersWithText, searchUsers, unSearchUsers
    , SortUsersBy(..)
    , UsersQueryApi, UsersQuery(..), mkUsersQuery, usersQueryF, usersQueryS

    , ClassesFilterQuery(..)
    , SearchClasses(..)
    , ClassesQueryApi
    , unSearchClasses, searchClasses, mkClassesQuery
    )
where

import GHC.TypeLits (Symbol, KnownSymbol, symbolVal)
import Servant.API ((:>), QueryParam, FromHttpApiData, ToHttpApiData, parseUrlPiece, toUrlPiece)

import qualified Data.Ord
import qualified Data.Text as ST
import qualified Generics.SOP as SOP

import AulaPrelude
import Data.UriPath
import Data.Map (Map)
import Persistent.Idiom (IdeaStats(..), ideaStatsIdea, ideaSupport)
import Types


-- * filter (also does sort)

-- | The associated type decides the values that are filtered / sorted.  See the
-- 'ClassesFilterQuery' instance below for a reasonably accessible example use case.
class Filter a where
    type Filtered a
    applyFilter  :: a -> [Filtered a] -> [Filtered a]
    renderFilter :: a -> UriPath -> UriPath

type family FilterName a :: Symbol

type FilterApi a = QueryParam (FilterName a) a

renderQueryParam :: forall a. (KnownSymbol (FilterName a), ToHttpApiData a) => a -> UriPath -> UriPath
renderQueryParam a p = p </?> (cs (symbolVal (Proxy :: Proxy (FilterName a))), Just . cs $ toUrlPiece a)

instance Filter a => Filter (Maybe a) where
    type Filtered (Maybe a) = Filtered a
    applyFilter  = maybe id applyFilter
    renderFilter = maybe id renderFilter


-- * filter and sort ideas

data IdeasFilterQuery = AllIdeas | IdeasWithCat { _catFilter :: Category }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeasFilterQuery

makeLenses ''IdeasFilterQuery
makePrisms ''IdeasFilterQuery

toggleIdeasFilter :: Category -> IdeasFilterQuery -> IdeasFilterQuery
toggleIdeasFilter cat q
    | q == IdeasWithCat cat = AllIdeas
    | otherwise             = IdeasWithCat cat

instance Filter   Category where
    type Filtered Category = IdeaStats
    applyFilter c = filter $ (== Just c) . view (ideaStatsIdea . ideaCategory)
    renderFilter  = renderQueryParam

type instance FilterName Category = "category"

instance Filter     IdeasFilterQuery where
    type Filtered   IdeasFilterQuery = IdeaStats
    applyFilter  f = applyFilter  $ f ^? catFilter
    renderFilter f = renderFilter $ f ^? catFilter

data SortIdeasBy = SortIdeasBySupport | SortIdeasByTime
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)

instance HasUILabel SortIdeasBy where
    uilabel = \case
        SortIdeasBySupport -> "Unterstützung"
        SortIdeasByTime    -> "Datum"

instance SOP.Generic SortIdeasBy

instance FromHttpApiData SortIdeasBy where
    parseUrlPiece = \case
        "time"    -> Right SortIdeasByTime
        "support" -> Right SortIdeasBySupport
        _         -> Left "no parse"

instance ToHttpApiData SortIdeasBy where
    toUrlPiece = \case
        SortIdeasByTime    -> "time"
        SortIdeasBySupport -> "support"

instance Filter   SortIdeasBy where
    type Filtered SortIdeasBy = IdeaStats

    applyFilter = \case
        SortIdeasByTime    -> byTime
        SortIdeasBySupport -> bySupport . byTime
      where
        byTime = downSortOn $ ideaStatsIdea . createdAt
        bySupport = downSortOn $ to (\(IdeaStats idea phase _ _) -> ideaSupport phase idea)

    renderFilter = renderQueryParam

type instance FilterName SortIdeasBy = "sortby"

newtype SearchTerm a = SearchTerm { _unSearchTerm :: ST }
    deriving (Eq, Ord, Show, Read, Generic, Monoid, ToHttpApiData, FromHttpApiData)

makeLenses ''SearchTerm

instance SOP.Generic (SearchTerm a)

class HasSearchTerm a where
    hasSearchTerm :: a -> SearchTerm b -> Bool

instance (HasSearchTerm a, HasSearchTerm b) => HasSearchTerm (a, b) where
    hasSearchTerm (x, y) t = hasSearchTerm x t || hasSearchTerm y t

instance (HasSearchTerm a, HasSearchTerm b, HasSearchTerm c) => HasSearchTerm (a, b, c) where
    hasSearchTerm (x, y, z) = hasSearchTerm (x, (y, z))

instance HasSearchTerm ST.Text where
    hasSearchTerm s t = (t ^. unSearchTerm) `ST.isInfixOf` s

instance HasSearchTerm Document where
    hasSearchTerm = hasSearchTerm . unMarkdown

instance HasSearchTerm v => HasSearchTerm (Map k v) where
    hasSearchTerm m t = anyOf each (`hasSearchTerm` t) m

instance HasSearchTerm Comment where
    hasSearchTerm c = hasSearchTerm (c ^. commentText, c ^. commentReplies)

instance HasSearchTerm Idea where
    hasSearchTerm i = hasSearchTerm (i ^. ideaTitle, i ^. ideaDesc)

instance HasSearchTerm IdeaStats where
    hasSearchTerm i = hasSearchTerm (i ^. ideaStatsIdea)

instance HasSearchTerm a => Filter (SearchTerm a) where
    type Filtered (SearchTerm a) = a
    applyFilter  t  | t == nil   = id
                    | otherwise  = filter prd
        where
            ts    = SearchTerm <$> ST.words (t ^. unSearchTerm)
            prd x = all (hasSearchTerm x) ts
    renderFilter t  | t == nil   = id
                    | otherwise  = renderQueryParam t

type instance FilterName (SearchTerm a) = "has"

data IdeasQuery = IdeasQuery
    { _ideasQueryT :: SearchTerm IdeaStats
    , _ideasQueryF :: IdeasFilterQuery
    , _ideasQueryS :: SortIdeasBy
    }
  deriving (Eq, Ord, Show, Read, Generic)

type IdeasQueryApi a = FilterApi (SearchTerm IdeaStats) :>
                       FilterApi Category :>
                       FilterApi SortIdeasBy :> a

instance SOP.Generic IdeasQuery

makeLenses ''IdeasQuery

mkIdeasQuery :: Maybe (SearchTerm IdeaStats) -> Maybe Category -> Maybe SortIdeasBy -> IdeasQuery
mkIdeasQuery mt mc ms =
    IdeasQuery (fromMaybe nil mt) (maybe AllIdeas IdeasWithCat mc) (fromMaybe minBound ms)

emptyIdeasQuery :: IdeasQuery
emptyIdeasQuery = IdeasQuery nil AllIdeas minBound

instance Filter IdeasQuery where
    type Filtered IdeasQuery = IdeaStats

    applyFilter  (IdeasQuery t f s) = applyFilter  s . applyFilter  f . applyFilter  t
    renderFilter (IdeasQuery t f s) = renderFilter s . renderFilter f . renderFilter t


-- * users sorting

data SortUsersBy = SortUsersByTime | SortUsersByName | SortUsersByClass | SortUsersByRole
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)

instance SOP.Generic SortUsersBy

instance FromHttpApiData SortUsersBy where
    parseUrlPiece = \case
        "time"  -> Right SortUsersByTime
        "name"  -> Right SortUsersByName
        "class" -> Right SortUsersByClass
        "role"  -> Right SortUsersByRole
        _       -> Left "no parse"

instance ToHttpApiData SortUsersBy where
    toUrlPiece = \case
        SortUsersByTime  -> "time"
        SortUsersByName  -> "name"
        SortUsersByClass -> "class"
        SortUsersByRole  -> "role"

instance Filter   SortUsersBy where
    type Filtered SortUsersBy = UserView

    applyFilter = \case
        SortUsersByTime  -> byTime
        SortUsersByName  -> byName  . byTime
        SortUsersByClass -> byClass . byTime
        SortUsersByRole  -> byRole  . byTime
      where
        by :: Ord a => Fold User a -> [UserView] -> [UserView]
        by f    = sortOn (pre $ activeUser . to (sort . toListOf f))
        byTime  = by $ createdAt . to Data.Ord.Down
        byName  = by userLogin
        byClass = by userSchoolClasses
        byRole  = by $ userRoles . uilabeledST

    renderFilter = renderQueryParam

type instance FilterName SortUsersBy = "sortby"

instance HasUILabel SortUsersBy where
    uilabel = \case
        SortUsersByTime  -> "Datum"
        SortUsersByName  -> "Name"
        SortUsersByClass -> "Klasse"
        SortUsersByRole  -> "Rolle"

newtype SearchUsers = SearchUsers { _unSearchUsers :: ST }
  deriving (Eq, Ord, Show, Read, Generic, FromHttpApiData, ToHttpApiData)

makeLenses ''SearchUsers

instance SOP.Generic SearchUsers

-- NOTE: SearchUsers could be replaced by SearchTerm and an instance of HasSearchTerm.
instance Filter SearchUsers where
    type Filtered SearchUsers = UserView

    applyFilter (SearchUsers t) = filter $ anyOf (activeUser . to searchee) (t `ST.isInfixOf`)
      where
        searchee :: User -> ST
        searchee u =
            ST.unwords $ u ^. userLogin . _UserLogin : u ^.. userSchoolClasses . uilabeled

    renderFilter = renderQueryParam

type instance FilterName SearchUsers = "search"

data UsersFilterQuery = AllUsers | UsersWithText { _searchUsers :: SearchUsers }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic UsersFilterQuery

makeLenses ''UsersFilterQuery
makePrisms ''UsersFilterQuery

instance Filter UsersFilterQuery where
    type Filtered UsersFilterQuery = UserView

    applyFilter  f = applyFilter  $ f ^? searchUsers
    renderFilter f = renderFilter $ f ^? searchUsers

data UsersQuery = UsersQuery
    { _usersQueryF :: UsersFilterQuery
    , _usersQueryS :: SortUsersBy
    }
  deriving (Eq, Ord, Show, Read, Generic)

type UsersQueryApi a = FilterApi SearchUsers :> FilterApi SortUsersBy :> a

instance SOP.Generic UsersQuery

makeLenses ''UsersQuery

instance Filter UsersQuery where
    type Filtered UsersQuery = UserView

    applyFilter  (UsersQuery f s) = applyFilter  s . applyFilter  f
    renderFilter (UsersQuery f s) = renderFilter s . renderFilter f

mkUsersQuery :: Maybe SearchUsers -> Maybe SortUsersBy -> UsersQuery
mkUsersQuery mf ms = UsersQuery (maybe AllUsers UsersWithText mf) (fromMaybe minBound ms)


-- * search school classes

newtype SearchClasses = SearchClasses { _unSearchClasses :: ST }
  deriving (Eq, Ord, Show, Read, Generic, FromHttpApiData, ToHttpApiData)

type ClassesQueryApi a = FilterApi SearchClasses :> a

data ClassesFilterQuery = AllClasses | ClassesWithText { _searchClasses :: SearchClasses }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic SearchClasses
instance SOP.Generic ClassesFilterQuery

makeLenses ''SearchClasses
makeLenses ''ClassesFilterQuery

type instance FilterName SearchClasses = "search"

instance Filter ClassesFilterQuery where
    type Filtered ClassesFilterQuery = SchoolClass

    applyFilter  AllClasses                            = id
    applyFilter  (ClassesWithText (SearchClasses qry)) = filter ((qry `ST.isInfixOf`) . uilabel)

    renderFilter AllClasses            = id
    renderFilter (ClassesWithText qry) = renderQueryParam qry

mkClassesQuery :: Maybe SearchClasses -> ClassesFilterQuery
mkClassesQuery = maybe AllClasses ClassesWithText
