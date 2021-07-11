{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
module TypeChecker where

import qualified Data.Map as Map
import Control.Monad
import Data.List
import Data.Either
import Data.Bifunctor
import Debug.Trace ( trace )
import Control.Monad.State
import Text.Megaparsec as P hiding (State)
import Text.Megaparsec.Pos (mkPos)
import Data.Functor
import qualified Data.Set as Set
import Data.Maybe
import Data.Tuple
import qualified Parser
import Nodes


insertAnnotation :: Lhs -> Finalizeable Annotation -> AnnotationState (Annotations (Finalizeable Annotation)) Annotation
insertAnnotation k v@(Finalizeable _ a) = do
    (a, ((i, Annotations b o), m)) <- get
    put (a, ((i, Annotations (Map.insert k v b) o), m))
    return a

getAnnotation :: Show a => Lhs -> Annotations a -> Result String a
getAnnotation k@(LhsIdentifer _ pos) (Annotations anns rest) =
    case Map.lookup k anns of
        Just v -> Right v
        Nothing -> 
            case rest of
                Just rs -> getAnnotation k rs
                Nothing -> Left $ show k ++ " not found in this scope\n" ++ showPos pos
getAnnotation k a = error $ "Unexpected args " ++ show (k, a)

modifyAnnotation :: Show a => Lhs -> a -> Annotations (Finalizeable a) -> Result String (Annotations (Finalizeable a))
modifyAnnotation k@(LhsIdentifer _ pos) ann (Annotations anns rest) =
    case Map.lookup k anns of
        Just (Finalizeable False v) -> Right $ Annotations (Map.insert k (Finalizeable False ann) anns) rest
        Just (Finalizeable True v) -> Left $ "Can not reconcile annotated " ++ show v ++ " with " ++ show ann ++ "\n" ++ showPos pos
        Nothing -> 
            case rest of
                Just rs -> case modifyAnnotation k ann rs of
                    Right a -> Right $ Annotations anns (Just a)
                    Left err -> Left err
                Nothing -> Left $ show k ++ " not found in this scope\n" ++ showPos pos
modifyAnnotation k ann as = error $ "Unexpected args " ++ show (k, ann, as)

modifyAnnotationState :: Show a => Lhs -> a -> AnnotationState (Annotations (Finalizeable a)) (Result String a)
modifyAnnotationState k v = do
    (a, ((i, anns), b)) <- get
    case modifyAnnotation k v anns of
        Right x -> (Right <$> put (a, ((i, x), b))) $> Right v
        Left err -> return $ Left err

finalizeAnnotations :: Annotations (Finalizeable a) -> Annotations (Finalizeable a)
finalizeAnnotations (Annotations anns Nothing) = Annotations (Map.map finalize anns) Nothing
finalizeAnnotations (Annotations anns (Just rest)) = Annotations (Map.map finalize anns) (Just $ finalizeAnnotations rest)

finalizeAnnotationState :: AnnotationState (Annotations (Finalizeable a)) ()
finalizeAnnotationState = modify (\(a, ((i, anns), b)) -> (a, ((i, finalizeAnnotations anns), b)))

getAnnotationState :: Show a => Lhs -> AnnotationState (Annotations (Finalizeable a)) (Result String a)
getAnnotationState k = get >>= \(_, ((_, anns), _)) -> return (fromFinalizeable <$> getAnnotation k anns)

getAnnotationStateFinalizeable :: Show a => Lhs -> AnnotationState (Annotations a) (Result String a)
getAnnotationStateFinalizeable k = get >>= \(_, ((_, anns), _)) -> return (getAnnotation k anns)

rigidizeTypeConstraints :: UserDefinedTypes -> Constraint -> Constraint
rigidizeTypeConstraints usts (ConstraintHas lhs cs) = ConstraintHas lhs $ rigidizeTypeConstraints usts cs 
rigidizeTypeConstraints usts (AnnotationConstraint ann) = AnnotationConstraint $ rigidizeTypeVariables usts ann

rigidizeTypeVariables :: UserDefinedTypes -> Annotation -> Annotation
rigidizeTypeVariables usts fid@(GenericAnnotation id cns) = RigidAnnotation id $ map (rigidizeTypeConstraints usts) cns
rigidizeTypeVariables usts fid@RigidAnnotation{} = fid
rigidizeTypeVariables usts id@AnnotationLiteral{} = id
rigidizeTypeVariables usts fid@(Annotation id) = fromMaybe (error $ noTypeFound id sourcePos) (Map.lookup (LhsIdentifer id sourcePos) usts)
rigidizeTypeVariables usts (NewTypeAnnotation id anns annMap) = NewTypeAnnotation id (map (rigidizeTypeVariables usts) anns) (Map.map (rigidizeTypeVariables usts) annMap)
rigidizeTypeVariables usts (NewTypeInstanceAnnotation id anns) = NewTypeInstanceAnnotation id (map (rigidizeTypeVariables usts) anns)
rigidizeTypeVariables usts (FunctionAnnotation args ret) = FunctionAnnotation (map (rigidizeTypeVariables usts) args) (rigidizeTypeVariables usts ret)
rigidizeTypeVariables usts (StructAnnotation ms) = StructAnnotation $ Map.map (rigidizeTypeVariables usts) ms
rigidizeTypeVariables usts (TypeUnion ts) = TypeUnion $ Set.map (rigidizeTypeVariables usts) ts
rigidizeTypeVariables usts OpenFunctionAnnotation{} = error "Can't use rigidizeVariables with open functions"

unrigidizeTypeConstraints :: UserDefinedTypes -> Constraint -> Constraint
unrigidizeTypeConstraints usts (ConstraintHas lhs cs) = ConstraintHas lhs $ rigidizeTypeConstraints usts cs 
unrigidizeTypeConstraints usts (AnnotationConstraint ann) = AnnotationConstraint $ rigidizeTypeVariables usts ann

unrigidizeTypeVariables :: UserDefinedTypes -> Annotation -> Annotation
unrigidizeTypeVariables usts fid@(GenericAnnotation id cns) = fid
unrigidizeTypeVariables usts fid@(RigidAnnotation id cns) = GenericAnnotation id $ map (unrigidizeTypeConstraints usts) cns
unrigidizeTypeVariables usts id@AnnotationLiteral{} = id
unrigidizeTypeVariables usts fid@(Annotation id) = fromMaybe (error $ noTypeFound id sourcePos) (Map.lookup (LhsIdentifer id sourcePos) usts)
unrigidizeTypeVariables usts (NewTypeAnnotation id anns annMap) = NewTypeAnnotation id (map (unrigidizeTypeVariables usts) anns) (Map.map (unrigidizeTypeVariables usts) annMap)
unrigidizeTypeVariables usts (NewTypeInstanceAnnotation id anns) = NewTypeInstanceAnnotation id (map (unrigidizeTypeVariables usts) anns)
unrigidizeTypeVariables usts (FunctionAnnotation args ret) = FunctionAnnotation (map (unrigidizeTypeVariables usts) args) (unrigidizeTypeVariables usts ret)
unrigidizeTypeVariables usts (StructAnnotation ms) = StructAnnotation $ Map.map (unrigidizeTypeVariables usts) ms
unrigidizeTypeVariables usts (TypeUnion ts) = TypeUnion $ Set.map (unrigidizeTypeVariables usts) ts
unrigidizeTypeVariables usts OpenFunctionAnnotation{} = error "Can't use rigidizeVariables with open functions"

pushScope :: Show a => AnnotationState (Annotations a) ()
pushScope = (\(a, ((i, mp), b)) -> put (a, ((i, Annotations Map.empty $ Just mp), b))) =<< get

popScope :: Show a => AnnotationState (Annotations a) ()
popScope = (\(a, ((i, Annotations _ (Just mp)), b)) -> put (a, ((i, mp), b))) =<< get

mapRight :: Monad m => m (Either a t) -> (t -> m (Either a b)) -> m (Either a b)
mapRight f f1 = do
        a <- f
        case a of
            Right a -> f1 a
            Left err -> return $ Left err

makeFunAnnotation args = FunctionAnnotation (map snd args)

isCallable :: Annotation -> Bool
isCallable FunctionAnnotation{} = True
isCallable _ = False

callError :: [Annotation] -> [Annotation] -> Either [Char] Annotation
callError fargs args = Left $ "Expected " ++ show fargs ++ " arguments but got " ++ show args ++ " args"

mapLeft s f = case s of
        Left x -> f x
        Right a ->  Right a

toEither def (Just a) = Right a
toEither def Nothing = Left def

getTypeState :: Annotation -> P.SourcePos -> State (Annotation, (b, UserDefinedTypes)) (Either String Annotation)
getTypeState (Annotation id) pos = do
    (_, (_, types)) <- get
    case Map.lookup (LhsIdentifer id pos) types of
        Just st -> return $ Right st
        Nothing -> return . Left $ "No type named " ++ id ++ " found\n" ++ showPos pos 
getTypeState a _ = return $ Right a

getTypeStateFrom :: AnnotationState a (Either String Annotation) -> SourcePos -> AnnotationState a (Either String Annotation)
getTypeStateFrom f pos = do
    res <- f
    case res of
        Right res -> getTypeState res pos
        Left err -> return $ Left err

firstInferrableReturn :: P.SourcePos -> [Node] -> AnnotationState (Annotations (Finalizeable Annotation)) (Either String Node)
firstInferrableReturn pos [] = return . Left $ "Could not infer the type of function at \n" ++ showPos pos
firstInferrableReturn pos (IfStmnt cond ts es _:xs) = do
    scope@(_, (_, mp)) <- get
    c <- getAssumptionType cond
    case sameTypes pos mp (AnnotationLiteral "Bool") <$> c of
        Right _ -> do
            t <- firstInferrableReturn pos ts
            case t of
                Right a -> return $ Right a
                Left _ -> do
                    put scope
                    e <- firstInferrableReturn pos es
                    case e of
                        Right a -> return $ Right a
                        Left err -> do
                            put scope
                            return $ Left err
        Left err -> return $ Left err
firstInferrableReturn pos (n@(DeclN (Decl _ rhs _ _)):xs) = do
    getAssumptionType n
    as <- firstInferrableReturn pos [rhs] 
    bs <- firstInferrableReturn pos xs
    return $ mapLeft as (const bs)
firstInferrableReturn pos (n@(DeclN (Assign _ rhs _)):xs) = do
    getAssumptionType n
    as <- firstInferrableReturn pos [rhs] 
    bs <- firstInferrableReturn pos xs
    return $ mapLeft as (const bs)
firstInferrableReturn pos ((Return a _):_) = return $ Right a
firstInferrableReturn pos (_:xs) = firstInferrableReturn pos xs

isGeneric :: P.SourcePos -> UserDefinedTypes -> Annotation -> Bool
isGeneric pos usts ann = evalState (go pos usts ann) Map.empty where
    go :: P.SourcePos -> UserDefinedTypes -> Annotation -> State (Map.Map Annotation Bool) Bool
    go pos mp GenericAnnotation{} = return True
    go pos mp (RigidAnnotation _ cns) = or <$> mapM goConstraints cns where
        goConstraints (ConstraintHas _ cn) = goConstraints cn
        goConstraints (AnnotationConstraint ann) = go pos mp ann
    go pos mp AnnotationLiteral{} = return False
    go pos mp wholeAnn@(Annotation ann) = do
        recordedAnns <- get
        case Map.lookup wholeAnn recordedAnns of
            Just b -> return b
            Nothing -> case Map.lookup (LhsIdentifer ann pos) mp of
                Just new_ann -> do
                    put $ Map.insert wholeAnn False recordedAnns
                    new_res <- go pos mp new_ann
                    put $ Map.insert wholeAnn new_res recordedAnns
                    return new_res
                Nothing -> return False
    go pos mp (FunctionAnnotation args ret) = or <$> mapM (go pos mp) (ret:args)
    go pos mp (StructAnnotation ms) = or <$> mapM (go pos mp) ms
    go pos mp (NewTypeAnnotation _ _ tmp) = or <$> mapM (go pos mp) tmp
    go pos mp (NewTypeInstanceAnnotation _ as) = or <$> mapM (go pos mp) as
    go pos mp (TypeUnion ts) = or <$> mapM (go pos mp) (Set.toList ts)
    go pos mp OpenFunctionAnnotation{} = return False

firstPreferablyDefinedRelation pos defs mp rs k =
    case Map.lookup k rs of
        Just s -> 
            if notnull stf then Right . defResIfNull $ inDefs stf 
            else if notnull deftf then Right . defResIfNull $ inDefs deftf  
            else case defRes of
                    Right x -> Right x
                    Left _ -> Right $ Set.elemAt 0 $ if notnull $ inDefs s then inDefs s else s
            where 
                notnull = not . Set.null
                deftf = Set.filter (`Set.member` defs) s
                stf = Set.filter (\x -> isJust (Map.lookup x mp)) s

                defResIfNull s = if notnull s then Set.elemAt 0 s else case defRes of
                    Right x -> x
                    Left _ -> Set.elemAt 0 s
        Nothing -> defRes
        where 
            inDefs s = Set.filter (`Set.member` defs) s
            defRes = 
                case Map.elems $ Map.filter (\s -> Set.member k s && not (Set.disjoint defs s)) $ Map.mapWithKey Set.insert rs of
                    [] -> Left $ "No relation of generic " ++ show k ++ " found\n" ++ showPos pos
                    xs -> Right $ Set.elemAt 0 $ inDefs $ head xs

substituteConstraintsOptFilter pred pos defs rels mp usts (ConstraintHas lhs cs) = ConstraintHas lhs <$> substituteConstraintsOptFilter pred pos defs rels mp usts cs 
substituteConstraintsOptFilter pred pos defs rels mp usts (AnnotationConstraint ann) = AnnotationConstraint <$> substituteVariablesOptFilter pred pos defs rels mp usts ann

substituteVariablesOptFilter pred pos defs rels mp usts fid@(GenericAnnotation id cns) = 
    maybe g (\x -> if sameTypesBool pos usts fid x then g else Right x) (Map.lookup fid mp)
    where 
        f x = case firstPreferablyDefinedRelation pos defs mp rels x of
            Right a -> Right a
            Left _ -> Right x
        g = mapM (substituteConstraintsOptFilter pred pos defs rels mp usts) cns >>= f . GenericAnnotation id
substituteVariablesOptFilter pred pos defs rels mp usts (RigidAnnotation id cns) = 
    case substituteVariablesOptFilter pred pos defs rels mp usts $ GenericAnnotation id cns of
        Right (GenericAnnotation id cns) -> Right $ RigidAnnotation id cns
        Right a -> Right a
        Left err -> Left err
substituteVariablesOptFilter pred pos defs rels mp usts id@AnnotationLiteral{} = Right id
substituteVariablesOptFilter pred pos defs rels mp usts fid@(Annotation id) = maybe (Left $ noTypeFound id pos) Right (Map.lookup (LhsIdentifer id pos) usts)
substituteVariablesOptFilter pred pos defs rels mp usts (NewTypeAnnotation id anns annMap) = NewTypeAnnotation id <$> mapM (substituteVariablesOptFilter pred pos defs rels mp usts) anns <*> mapM (substituteVariablesOptFilter pred pos defs rels mp usts) annMap
substituteVariablesOptFilter pred pos defs rels mp usts (NewTypeInstanceAnnotation id anns) = NewTypeInstanceAnnotation id <$> mapM (substituteVariablesOptFilter pred pos defs rels mp usts) anns
substituteVariablesOptFilter pred pos defs rels mp usts (FunctionAnnotation args ret) = FunctionAnnotation <$> mapM (substituteVariablesOptFilter pred pos defs rels mp usts) args <*> substituteVariablesOptFilter pred pos defs rels mp usts ret
substituteVariablesOptFilter pred pos defs rels mp usts (StructAnnotation ms) = StructAnnotation <$> mapM (substituteVariablesOptFilter pred pos defs rels mp usts) ms
substituteVariablesOptFilter pred pos defs rels mp usts (TypeUnion ts) = 
    foldr1 (mergedTypeConcrete pos usts) . (if pred then filter (not . isGeneric pos usts) else id) <$> mapM (substituteVariablesOptFilter pred pos defs rels mp usts) (Set.toList ts)
substituteVariablesOptFilter pred pos defs rels mp usts OpenFunctionAnnotation{} = error "Can't use substituteVariables with open functions"

substituteVariables = substituteVariablesOptFilter True

collectGenericConstraints :: UserDefinedTypes -> Constraint -> Set.Set Annotation
collectGenericConstraints usts (ConstraintHas lhs cs) = collectGenericConstraints usts cs 
collectGenericConstraints usts (AnnotationConstraint ann) = collectGenenrics usts ann

collectGenenrics :: UserDefinedTypes -> Annotation -> Set.Set Annotation
collectGenenrics usts fid@(GenericAnnotation id cns) = Set.singleton fid `Set.union` Set.unions (map (collectGenericConstraints usts) cns)
collectGenenrics usts fid@(RigidAnnotation id cns) = Set.singleton fid `Set.union` Set.unions (map (collectGenericConstraints usts) cns)
collectGenenrics usts AnnotationLiteral{} = Set.empty
collectGenenrics usts fid@(Annotation ident) = maybe (error "Run your passes in order. You should know that this doesn't exists by now") (collectGenenrics usts) (Map.lookup (LhsIdentifer ident (SourcePos "" (mkPos 0) (mkPos 0))) usts)
collectGenenrics usts (NewTypeAnnotation id anns annMap) = Set.unions (Set.map (collectGenenrics usts) (Set.fromList anns)) `Set.union` foldl1 Set.union (map (collectGenenrics usts) (Map.elems annMap))
collectGenenrics usts (NewTypeInstanceAnnotation id anns) = Set.unions $ Set.map (collectGenenrics usts) (Set.fromList anns)
collectGenenrics usts (FunctionAnnotation args ret) = Set.empty
collectGenenrics usts (StructAnnotation ms) = Set.unions $ Set.map (collectGenenrics usts) (Set.fromList $ Map.elems ms)
collectGenenrics usts (TypeUnion ts) = Set.unions $ Set.map (collectGenenrics usts) ts
collectGenenrics usts (OpenFunctionAnnotation args ret ftr _) = Set.unions $ Set.map (collectGenenrics usts) $ Set.fromList (args++[ret, ftr])

getLookupTypeIfAvailable :: Annotation -> SubstituteState Annotation
getLookupTypeIfAvailable k = do
    (a, ((rs, mp), usts)) <- get
    case Map.lookup k mp of
        Just k -> getLookupTypeIfAvailable k
        Nothing -> return k

changeType :: P.SourcePos -> Set.Set Annotation -> Annotation -> Annotation -> SubstituteState (Either String ())
changeType pos defs k v = do
    (a, ((rel, mp), usts)) <- get
    case substituteVariables pos defs rel mp usts v of
        Right sub -> put (a, ((rel, Map.insert k sub mp), usts)) $> Right ()
        Left err -> return $ Left err

reshuffleTypes :: P.SourcePos -> Set.Set Annotation -> SubstituteState ()
reshuffleTypes pos defs = (\(_, ((_, mp), _)) -> sequence_ $ Map.mapWithKey (changeType pos defs) mp) =<< get

sameTypesNoUnionSpec = sameTypesGeneric (False, True, Map.empty)

addTypeVariableGeneralized n pos defs stmnt k v = do
        (a, ((rs, mp), usts)) <- get
        case Map.lookup k mp of
            Nothing -> addToMap a rs mp usts k v
            Just a -> do
                case sameTypesNoUnionSpec pos usts a v of
                    Left err -> if a == AnnotationLiteral "_" then addToMap a rs mp usts k v else 
                        case Map.lookup k rs of
                            Just st -> if Set.member v st then addToMap a rs mp usts k v else return $ Left err
                            Nothing -> 
                                if n > 0 then do
                                    reshuffleTypes pos defs
                                    addTypeVariableGeneralized (n-1) pos defs stmnt k v
                                    else return $ Left err
                    Right a -> addToMap a rs mp usts k v
    where
        addToMap a rs mp usts k v = do
            put (a, ((rs, Map.insert k v mp), usts))
            stmnt
            reshuffleTypes pos defs
            return $ Right v

addTypeVariable :: SourcePos -> Set.Set Annotation -> Annotation -> Annotation -> SubstituteState (Either String Annotation)
addTypeVariable pos defs = addTypeVariableGeneralized 5 pos defs (updateRelations pos defs)

-- This is written horribly, rewrite it
updateSingleRelation pos defs r = do
    (a, ((rs, mp), usts)) <- get
    case Map.lookup r rs of
        Just rl -> do
            (\case 
                Right _ -> do
                    put (a, ((Map.insert r (getAllRelationsInvolving r rs) rs, mp), usts))
                    maybe (return $ Right ()) (\a -> f r a $> Right ()) fnv
                Left err -> return $ Left err) . sequence =<< mapM (uncurry f) mls'
            where 
            m = Map.filterWithKey (\k _ -> k `Set.member` rl) mp
            mls = Map.toList m
            fnv = firstNonUnderscore mls
            mls' = case fnv of 
                Just a -> map (\(k, _) -> (k, a)) mls
                Nothing -> []
            f = addTypeVariableGeneralized 5 pos defs (return $ Right ())

            firstNonUnderscore [] = Nothing 
            firstNonUnderscore ((_, AnnotationLiteral "_"):xs) = firstNonUnderscore xs
            firstNonUnderscore ((_, ann):xs) = Just ann

            getAllRelationsInvolving r rs = Set.unions $ Map.elems $ Map.filter (Set.member r) $ Map.mapWithKey Set.insert rs
        Nothing -> return . Left $ "No relation on " ++ show r ++ " has been established"

updateRelations :: P.SourcePos -> Set.Set Annotation -> SubstituteState (Either String ())
updateRelations pos defs = do
    (a, ((rs, mp), usts)) <- get
    x <- mapM (updateSingleRelation pos defs) $ Map.keys rs
    case sequence x of
        Right _ -> return $ Right ()
        Left err -> return $ Left err

addRelation :: P.SourcePos -> Set.Set Annotation -> Annotation -> Annotation -> SubstituteState (Either String ())
addRelation pos defs r nv = do
    (a, ((rs, mp), usts)) <- get
    case Map.lookup r rs of
        Just rl -> do
            let nrs = Map.insert r (rl `Set.union` Set.singleton nv) rs
            put (a, ((nrs, mp), usts))
            Right () <$ updateSingleRelation pos defs r
        Nothing -> do
            let nrs = Map.insert r (Set.singleton nv) rs
            put (a, ((nrs, mp), usts))
            Right () <$ updateSingleRelation pos defs r

applyConstraintState :: SourcePos -> Set.Set Annotation -> Annotation -> Constraint -> SubstituteState (Either String Annotation)
applyConstraintState pos defs ann (ConstraintHas lhs cn) = 
    do 
        mp <- getTypeMap
        case ann of
            StructAnnotation mp -> 
                case lhs `Map.lookup` mp of
                    Just ann -> applyConstraintState pos defs ann cn
                    Nothing -> return . Left $ "No field named " ++ show lhs ++ " found in " ++ show ann ++ "\n" ++ showPos pos
            Annotation id ->
                case LhsIdentifer id pos `Map.lookup` mp of
                    Just ann -> applyConstraintState pos defs ann cn
                    Nothing -> return . Left $ "No type named " ++ id ++ " found\n" ++ showPos pos
            NewTypeInstanceAnnotation id args -> 
                        accessNewType args
                        (\(NewTypeAnnotation _ _ ps) -> 
                            case Map.lookup lhs ps of
                                Just ann -> applyConstraintState pos defs ann cn
                                Nothing -> return . Left $ "Could not find " ++ show lhs ++ " in " ++ show ps ++ "\n" ++ showPos pos
                            ) 
                        (LhsIdentifer id pos)
            g@(GenericAnnotation id cns) -> return $ genericHas pos mp lhs cns
            t@TypeUnion{} -> typeUnionHas pos defs t cn
            a -> return . Left $ "Can't search for field " ++ show lhs ++ " in " ++ show a ++ "\n" ++ showPos pos
applyConstraintState pos defs ann2 (AnnotationConstraint ann1) = do
    a <- if isGenericAnnotation ann2 && isGenericAnnotation ann1 then addRelation pos defs ann2 ann1 *> addRelation pos defs ann1 ann2 $> Right ann1 else addTypeVariable pos defs ann1 ann2
    case a of
        Right _ -> specifyInternal pos defs ann1 ann2
        Left err -> return $ Left err

typeUnionHas pos defs (TypeUnion st) cn = (\case
                Left err -> return $ Left err
                Right stl -> do
                    a <- sequence <$> mapM (flip (applyConstraintState pos defs) cn) stl
                    case a of
                        Right (x:_) -> return $ Right x
                        Left err -> return $ Left err
                ) . sequence =<< mapM (flip (applyConstraintState pos defs) cn) stl where stl = Set.toList st
typeUnionHas _ _ t _ = error $ "typeUnionHas can only be called with type union, not " ++ show t

isValidNewTypeInstance = undefined

isGeneralizedInstance pos ann@(NewTypeInstanceAnnotation id1 anns1) = do
    a <- fullAnotationFromInstance pos ann
    case a of
        Right (NewTypeAnnotation id2 anns2 _) -> return $ id1 == id2 && length anns1 < length anns2
        Right _ -> return False
        Left err -> return False
isGeneralizedInstance a b = error $ "Unexpected argments for isGeneralizedInstance [" ++ show a ++ ", " ++ show b ++ "]"

isGeneralizedInstanceFree :: SourcePos -> Annotation -> Map.Map Lhs Annotation -> Bool
isGeneralizedInstanceFree pos ann@(NewTypeInstanceAnnotation id1 anns1) mp =
    case fullAnotationFromInstanceFree pos mp ann of
        Right (NewTypeAnnotation id2 anns2 _) -> id1 == id2 && length anns1 < length anns2
        Right _ -> False
        Left err -> False
isGeneralizedInstanceFree a b c = error $ "Unexpected argments for isGeneralizedInstance [" ++ show a ++ ", " ++ show b ++ ", " ++ show c ++ "]"

specifyInternal :: SourcePos
    -> Set.Set Annotation
    -> Annotation
    -> Annotation
    -> SubstituteState (Either String Annotation)
specifyInternal pos defs a@AnnotationLiteral{} b@AnnotationLiteral{} = (\mp -> return $ sameTypes pos mp a b *> Right a) =<< gets (snd . snd)
specifyInternal pos defs a@(RigidAnnotation id1 cns1) b@(RigidAnnotation id2 cns2) 
    | id1 == id2 = (b <$) <$> (sequence <$> mapM (applyConstraintState pos defs b) cns1)
    | otherwise = return . Left $ unmatchedType a b pos
specifyInternal pos defs a@(GenericAnnotation id cns) b@(AnnotationLiteral ann) = do
    mp <- getTypeMap
    ann <- addTypeVariable pos defs a b
    case ann of
        Right ann ->
            (\case
                Right _ -> return $ Right b
                Left err -> return $ Left err) . sequence =<< mapM (applyConstraintState pos defs ann) cns
        Left err -> return $ Left err
specifyInternal pos defs a@(GenericAnnotation id cns) b@(Annotation ann) = do
    anno <- getTypeState b pos
    case anno of
        Right ann -> specifyInternal pos defs a ann
        Left err -> return $ Left err
specifyInternal pos defs a@(Annotation id1) b@(Annotation id2) 
    | id1 == id2 = return $ Right b
    | otherwise = (\mp -> case Map.lookup (LhsIdentifer id1 pos) mp of 
        Just a' -> case Map.lookup (LhsIdentifer id2 pos) mp of
            Just b' -> specifyInternal pos defs a' b'
            Nothing -> undefined
        Nothing -> return $ Left $ noTypeFound id1 pos) =<< getTypeMap
specifyInternal pos defs a@(Annotation id) b = (\mp -> case Map.lookup (LhsIdentifer id pos) mp of 
        Just a' -> specifyInternal pos defs a' b
        Nothing -> return $ Left $ noTypeFound id pos) =<< getTypeMap
specifyInternal pos defs a b@(Annotation id) = (\mp -> case Map.lookup (LhsIdentifer id pos) mp of 
    Just b' -> specifyInternal pos defs a b'
    Nothing -> return $ Left $ noTypeFound id pos) =<< getTypeMap
specifyInternal pos defs a@(GenericAnnotation id1 cns1) b@(GenericAnnotation id2 cns2) = do
    (\case
        Right _ -> addRelation pos defs b a *> addRelation pos defs a b $> Right b
        Left err -> return $ Left err
        ) . sequence =<< mapM (applyConstraintState pos defs b) cns1
specifyInternal pos defs a@(GenericAnnotation id cns) b@(TypeUnion st) = (\case
        Right _ -> do
            a <- addTypeVariable pos defs a b
            case a of
                Right _ -> return $ Right b
                Left err -> return $ Left err
        Left err -> return $ Left err) . sequence =<< mapM (applyConstraintState pos defs b) cns
specifyInternal pos defs a@(StructAnnotation ms1) b@(StructAnnotation ms2)
    | Map.size ms1 /= Map.size ms2 = return . Left $ unmatchedType a b pos
    | Set.fromList (Map.keys ms1) == Set.fromList (Map.keys ms2) = (\case
        Right _ -> return $ Right b
        Left err -> return $ Left err) . sequence =<< zipWithM (specifyInternal pos defs) (Map.elems ms1) (Map.elems ms2)
specifyInternal pos defs a@(OpenFunctionAnnotation oargs oret _ _) b@(FunctionAnnotation args ret) 
    | length args /= length oargs = return $ callError oargs args
    | otherwise = (\case
        Right _ -> return $ Right b
        Left err -> return $ Left err
        ) . sequence =<< zipWithM (specifyInternal pos defs) (oargs ++ [oret]) (args ++ [ret])
specifyInternal pos defs a@(FunctionAnnotation oargs oret) b@(FunctionAnnotation args ret)
    | length args /= length oargs = return $ callError oargs args
    | otherwise = (\case
        Right _ -> return $ Right b
        Left err -> return $ Left err
        ) . sequence =<< zipWithM (specifyInternal pos defs) (oargs ++ [oret]) (args ++ [ret])
specifyInternal pos defs a@(NewTypeAnnotation id1 anns1 _) b@(NewTypeInstanceAnnotation id2 anns2) 
    | id1 /= id2 = return . Left $ unmatchedType a b pos
    | otherwise = specifyInternal pos defs (NewTypeInstanceAnnotation id1 anns1) b
specifyInternal pos defs a@(NewTypeInstanceAnnotation id1 anns1) b@(NewTypeInstanceAnnotation id2 anns2) 
    | id1 /= id2 = (\mp -> return $ sameTypes pos mp a b) =<< getTypeMap
    | otherwise  = do
        pred <- isGeneralizedInstance pos a
        if pred then do
            x <- fullAnotationFromInstance pos a
            case x of
                Right ntp@(NewTypeAnnotation id anns mp) -> specifyInternal pos defs ntp b
                Right _ -> return . Left $ noTypeFound id1 pos
                Left err -> return $ Left err
        else (\case
                Right _ -> return $ Right b
                Left err -> return $ Left err
                ) . sequence =<< zipWithM (specifyInternal pos defs) anns1 anns2
specifyInternal pos defs a@(TypeUnion as) b@(TypeUnion bs) = do
    mp <- getTypeMap
    case (foldr1 (mergedTypeConcrete pos mp) as, foldr1 (mergedTypeConcrete pos mp) bs) of
        (TypeUnion as, TypeUnion bs) -> do
            xs <- sequence <$> mapM (f mp $ Set.toList as) (Set.toList bs)
            case xs of
                Right _ -> return $ Right b
                Left err -> 
                    if Set.size as == Set.size bs && Set.null (collectGenenrics mp a) then return $ Left err 
                    else distinctUnion err (Set.toList $ collectGenenrics mp a)
        (a, b) -> specifyInternal pos defs a b
    where
        f mp ps2 v1 = getFirst a b pos $ map (\x -> specifyInternal pos defs x v1) ps2
        typeUnionList (TypeUnion xs) action = action $ Set.toList xs
        typeUnionList a action = specifyInternal pos defs a b
        distinctUnion err [] = return $ Left err
        distinctUnion _ xs = do
            usts <- getTypeMap
            c1 <- specifyInternal pos defs (head xs) (foldr1 (mergedTypeConcrete pos usts) $ take (length xs) (Set.toList as))
            c2 <- sequence <$> zipWithM (flip (specifyInternal pos defs)) (tail xs) (drop (length xs) (Set.toList as))
            case (c1, c2) of
                (Right _, Right _) -> return $ Right $ mergedTypeConcrete pos usts b b
                (Left err, _) -> return $ Left err
                (_, Left err) -> return $ Left err
specifyInternal pos defs a b@(TypeUnion st) = do
    x <- sequence <$> mapM (flip (specifyInternal pos defs) a) stl
    case x of
        Right a -> return . Right $ head a
        Left err -> return $ Left err
    where stl = Set.toList st
specifyInternal pos defs a@(TypeUnion st) b = getFirst a b pos $ map (flip (specifyInternal pos defs) b) $ Set.toList st
specifyInternal pos defs a@(GenericAnnotation id cns) b = 
    (\case
        Right _ -> do
            a <- addTypeVariable pos defs a b
            case a of
                Right _ -> return $ Right b
                Left err -> return $ Left err
        Left err -> return $ Left err) . sequence =<< mapM (applyConstraintState pos defs b) cns
specifyInternal pos defs a b = (\mp -> return $ sameTypes pos mp a b) =<< getTypeMap

getFirst a b pos [] = return . Left $ unmatchedType a b pos
getFirst a b pos (x:xs) = x >>= \case
    Right a -> return $ Right a
    Left _ -> getFirst a b pos xs

specify :: SourcePos -> Set.Set Annotation -> Map.Map Annotation Annotation -> UserDefinedTypes -> Annotation -> Annotation -> Either String (Annotation, TypeRelations)
specify pos defs base mp a b = (,rel) <$> ann where (ann, (ann1, ((rel, nmp), usts))) = runState (specifyInternal pos defs a b) (a, ((Map.empty, base), mp))

getPartialSpecificationRules :: SourcePos -> Set.Set Annotation -> Map.Map Annotation Annotation -> UserDefinedTypes -> Annotation -> Annotation -> (Map.Map Annotation Annotation, TypeRelations)
getPartialSpecificationRules pos defs base mp a b = (nmp, rel) where (ann, (ann1, ((rel, nmp), usts))) = runState (specifyInternal pos defs a b) (a, ((Map.empty, base), mp))

getPartialNoUnderScoreSpecificationRules :: SourcePos -> Set.Set Annotation -> Map.Map Annotation Annotation -> UserDefinedTypes -> Annotation -> Annotation -> (Map.Map Annotation Annotation, TypeRelations)
getPartialNoUnderScoreSpecificationRules pos defs base mp a b = 
    (Map.mapWithKey (\k a -> if a == AnnotationLiteral "_" then k else a) nmp, rel) where (nmp, rel) = getPartialSpecificationRules pos defs base mp a b

getSpecificationRules :: SourcePos -> Set.Set Annotation -> Map.Map Annotation Annotation -> UserDefinedTypes  -> Annotation -> Annotation -> Either String (Map.Map Annotation Annotation)
getSpecificationRules pos defs base mp a b = case fst st of
    Right _ -> Right (snd $ fst $ snd $ snd st)
    Left err -> Left err 
    where st = runState (specifyInternal pos defs a b) (a, ((Map.empty, base), mp))


sameTypesGenericBool gs crt pos mp a b = case sameTypesGeneric gs pos mp a b of
    Right _ -> True
    Left _ -> False

sameTypesBool pos mp a b = case sameTypes pos mp a b of
    Right _ -> True
    Left _ -> False

specifyTypesBool pos defs base usts a b = case specify pos defs base usts a b of
    Right _ -> True
    Left _ -> False                                     

isGenericAnnotation a = case a of 
    a@GenericAnnotation{} -> True
    _ -> False

expectedUnion pos lhs ann = "Expected a type union, got type " ++ show ann ++ " from " ++ show lhs ++ "\n" ++ showPos pos

fNode f x = head $ f [x]

earlyReturnToElse :: [Node] -> [Node]
earlyReturnToElse [] = []
earlyReturnToElse (IfStmnt c ts [] pos:xs) = 
    if isReturn $ last ts then [IfStmnt c (earlyReturnToElse ts) (earlyReturnToElse xs) pos]
    else IfStmnt c (earlyReturnToElse ts) [] pos : earlyReturnToElse xs
    where 
        isReturn a@Return{} = True
        isReturn _ = False
earlyReturnToElse (IfStmnt c ts es pos:xs) = IfStmnt c (earlyReturnToElse ts) (earlyReturnToElse es) pos : earlyReturnToElse xs
earlyReturnToElse (FunctionDef args ret ns pos:xs) = FunctionDef args ret (earlyReturnToElse ns) pos : earlyReturnToElse xs
earlyReturnToElse (DeclN (Decl lhs n ann pos):xs) = DeclN (Decl lhs (fNode earlyReturnToElse n) ann pos) : earlyReturnToElse xs
earlyReturnToElse (DeclN (Assign lhs n pos):xs) = DeclN (Assign lhs (fNode earlyReturnToElse n) pos) : earlyReturnToElse xs
earlyReturnToElse (x:xs) = x : earlyReturnToElse xs

freshDecl :: P.SourcePos -> Node -> TraversableNodeState Decl
freshDecl pos node = do
    (i, xs) <- get
    let id = LhsIdentifer ("__new_lifted_lambda_" ++ show i) pos
    put (i+1, xs ++ [Decl id node Nothing pos])
    return $ Decl id node Nothing pos

getDecls :: TraversableNodeState [Decl]
getDecls = get >>= \(_, xs) -> return xs

putDecls :: TraversableNodeState a -> TraversableNodeState a
putDecls action = do
    modify $ \(a, _) -> (a, [])
    action

inNewScope :: TraversableNodeState a -> TraversableNodeState a
inNewScope action = do
    (a, xs) <- get
    put (a+1, [])
    res <- action
    put (a, xs)
    return res

lastRegisteredId :: TraversableNodeState String
lastRegisteredId = do
    (i, _) <- get
    return ("__new_lifted_lambda_" ++ show (i-1))

registerNode :: Node -> TraversableNodeState Node
registerNode n@(FunctionDef args ret body pos) = do 
    mbody <- inNewScope $ liftLambda body
    decl <- freshDecl pos $ FunctionDef args ret mbody pos
    id <- lastRegisteredId
    return $ Identifier id pos
registerNode (IfStmnt c ts es pos) = putDecls $ do
    cx <- registerNode c
    tsx <- inNewScope $ liftLambda ts
    esx <- inNewScope $ liftLambda es
    return $ IfStmnt cx tsx esx pos
registerNode (Call e args pos) = Call <$> registerNode e <*> mapM registerNode args <*> return pos
registerNode (Return n pos) = flip Return pos <$> registerNode n
registerNode (StructN (Struct mp pos)) = StructN . flip Struct pos <$> mapM registerNode mp
registerNode (IfExpr c t e pos) = IfExpr <$> registerNode c <*> registerNode t <*> registerNode e <*> return pos
registerNode (Access n lhs pos) = flip Access lhs <$> registerNode n <*> return pos
registerNode (CreateNewType lhs args pos) = CreateNewType lhs <$> mapM registerNode args <*> return pos
registerNode a = return a

getRegister :: Node -> TraversableNodeState (Node, [Decl])
getRegister n = (,) <$> registerNode n <*> getDecls

liftLambda :: [Node] -> TraversableNodeState [Node]
liftLambda [] = return []
liftLambda (DeclN (ImplOpenFunction lhs args ret body ftr pos):xs) = putDecls $ do
    rest <- liftLambda xs
    (\mbody -> DeclN (ImplOpenFunction lhs args ret mbody ftr pos) : rest) <$> liftLambda body
liftLambda (DeclN opf@OpenFunctionDecl{}:xs) = (DeclN opf : ) <$> liftLambda xs
liftLambda (DeclN (Decl lhs (FunctionDef args ret body fpos) ann pos):xs) =  putDecls $ do
    mbody <- inNewScope $ liftLambda body
    rest <- liftLambda xs
    return $ DeclN (Decl lhs (FunctionDef args ret mbody fpos) ann pos) : rest
liftLambda (DeclN (Decl lhs n ann pos):xs) = putDecls $ do
    getRegister n >>= \(x, ds) -> (map DeclN ds ++) . (DeclN (Decl lhs x ann pos) :) <$> liftLambda xs
liftLambda (DeclN (Assign lhs (FunctionDef args ret body fpos) pos):xs) = putDecls $ do
    mbody <- inNewScope $ liftLambda body
    rest <- liftLambda xs
    return $ DeclN (Assign lhs (FunctionDef args ret mbody fpos) pos) : rest
liftLambda (DeclN (Assign lhs n pos):xs) =
    putDecls $ getRegister n >>= \(x, ds) -> (map DeclN ds ++) . (DeclN (Assign lhs x pos) :) <$> liftLambda xs
liftLambda (DeclN (Expr n):xs) = 
    putDecls $ getRegister n >>= \(x, ds) -> (map DeclN ds ++) . (DeclN (Expr x) :) <$> liftLambda xs
liftLambda (n:ns) = putDecls $ getRegister n >>= \(x, ds) -> (map DeclN ds ++) . (x :) <$> liftLambda ns

initIdentLhs :: Lhs -> Lhs
initIdentLhs (LhsAccess acc p pos) = LhsIdentifer id pos where (Identifier id pos) = initIdent $ Access acc p pos
initIdentLhs n = error $ "Only call initIdent with " ++ show n

initIdent (Access id@Identifier{} _ _) = id
initIdent (Access x _ _) = initIdent x
initIdent n = error $ "Only call initIdent with " ++ show n

trimAccess (Access (Access id p pos) _ _) = Access id p pos
trimAccess n = error $ "Only call initIdent with " ++ show n

makeUnionIfNotSame pos a clhs lhs = do
    case a of
        Right a -> join $ (\b m -> 
            case b of
                Left err -> return $ Left err
                Right (AnnotationLiteral "_") -> modifyAnnotationState lhs a
                Right b ->
                    do 
                        x <- getTypeState a pos 
                        case x of 
                            Right a -> 
                                case sameTypesImpl a pos m b a of
                                    Left _ -> f a m (Right b)
                                    Right _ -> return $ Right a
                            Left err -> return $ Left err
            ) <$> clhs <*> getTypeMap 
        Left err -> return $ Left err
    where
        f a m = \case
                Right b -> modifyAnnotationState lhs $ mergedTypeConcrete pos m a b
                Left err -> return $ Left err

modifyWhole :: [Lhs] -> Annotation -> Annotation -> AnnotationState a Annotation
modifyWhole (p:xs) whole@(StructAnnotation ps) given = case Map.lookup p ps of
    Just a -> modifyWhole xs a given >>= \x -> return . StructAnnotation $ Map.insert p x ps
    Nothing -> error $ "You should already know that " ++ show p ++  " is in " ++ show ps ++ " before comming here"
modifyWhole [] _ given = return given

listAccess n = reverse $ go n where
    go (Access n lhs _) = lhs : listAccess n
    go Identifier{} = []

makeImpl a b TypeUnion{} = a
makeImpl a b (NewTypeInstanceAnnotation _ xs) = 
    if isJust $ find isTypeUnion xs then a else b where
    isTypeUnion TypeUnion{} = True
    isTypeUnion _ = False
makeImpl a b _ = b

sameTypesImpl :: Annotation -> SourcePos -> UserDefinedTypes -> Annotation -> Annotation -> Either String Annotation
sameTypesImpl = makeImpl sameTypesNoUnionSpec sameTypes

matchingUserDefinedType :: P.SourcePos -> Set.Set Annotation -> UserDefinedTypes -> Annotation -> Maybe Annotation
matchingUserDefinedType pos defs usts t = (\(LhsIdentifer id _, _) -> Just $ Annotation id) =<< find (isRight . snd) (Map.mapWithKey (,) $ Map.map (flip (specify pos defs Map.empty usts) t) usts)

getAssumptionType :: Node -> AnnotationState (Annotations (Finalizeable Annotation)) (Result String Annotation)
getAssumptionType (DeclN (Decl lhs n a _)) = case a of 
    Just a -> Right <$> insertAnnotation lhs (Finalizeable True a)
    Nothing -> mapRight (getAssumptionType n) (fmap Right . insertAnnotation lhs . Finalizeable False)
getAssumptionType (DeclN (Assign lhs@(LhsAccess access p accPos) expr pos)) = 
    do
        expcd <- getAssumptionType (Access access p accPos)
        rhs <- getTypeStateFrom (getAssumptionType expr) pos
        full <- getTypeStateFrom (getAnnotationState $ initIdentLhs lhs) pos
        mp <- getTypeMap
        case (full, expcd, rhs) of
            (Right whole, Right expcd, Right rhs) ->
                case sameTypesImpl rhs pos mp expcd rhs of
                    Right a -> return $ Right a
                    Left _ -> do
                        x <- modifyAccess mp pos (Access access p accPos) whole expcd rhs p access accPos getAssumptionType
                        case x of
                            Right x -> modifyAnnotationState (initIdentLhs lhs) x
                            Left err -> return $ Left err
            (Left err, _, _) -> return $ Left err
            (_, Left err, _) -> return $ Left err
            (_, _, Left err) -> return $ Left err
getAssumptionType (DeclN (Assign lhs n pos)) = getAssumptionType n >>= \x -> makeUnionIfNotSame pos x (getAnnotationState lhs) lhs
getAssumptionType (DeclN (FunctionDecl lhs ann _)) = Right <$> insertAnnotation lhs (Finalizeable False ann)
getAssumptionType (CreateNewType lhs args pos) = do
    mp <- getTypeMap
    argsn <- sequence <$> mapM getAssumptionType args
    case argsn of
        Right as -> return $ case Map.lookup lhs mp of
            Just (NewTypeAnnotation id anns _) -> 
                if length anns == length args then NewTypeInstanceAnnotation id <$> argsn
                else Left $ "Can't match arguments " ++ show as ++ " with " ++ show anns
            Just a -> error (show a)
            Nothing -> Left $ noTypeFound (show lhs) pos
        Left err -> return $ Left err
getAssumptionType (DeclN (OpenFunctionDecl lhs ann _)) = Right <$> insertAnnotation lhs (Finalizeable False ann)
getAssumptionType (DeclN impl@(ImplOpenFunction lhs args (Just ret) ns implft pos)) = do
    a <- getAnnotationState lhs
    mp <- getTypeMap
    case a of
        Left err -> return $ Left err
        Right a@(OpenFunctionAnnotation anns ret' ft impls) -> do
            let b = makeFunAnnotation args ret
            case getSpecificationRules pos Set.empty Map.empty mp ft implft of
                Right base -> 
                    case getSpecificationRules pos Set.empty base mp a b of
                        Left err -> return $ Left err
                        Right res -> 
                                    let 
                                        aeq = Set.fromList $ Map.keys $ Map.filterWithKey (\a b -> isGenericAnnotation a && not (sameTypesBool pos mp a b)) res
                                        beq = Set.fromList $ Map.keys $ Map.filterWithKey (\a b -> isGenericAnnotation a && not (sameTypesBool pos mp a b)) base
                                    in
                                    if aeq == beq then 
                                        Right <$> insertAnnotation lhs (Finalizeable True (OpenFunctionAnnotation anns ret' ft $ implft:impls))
                                    else return . Left $ "Forbidden to specify specified type variables\n" ++ showPos pos
                Left err -> return $ Left err
        Right a -> return . Left $ "Cannot extend function " ++ show a ++ "\n" ++ showPos pos
getAssumptionType (DeclN (ImplOpenFunction lhs args Nothing ns implft pos)) = do
    a <- getAnnotationState lhs
    mp <- getTypeMap
    case a of
        Left err -> return $ Left err
        Right fun@(OpenFunctionAnnotation anns ret' ft impls) -> 
            case getSpecificationRules pos Set.empty Map.empty mp ft implft of
                Right base -> do
                    let (specificationRules, rels) = getPartialNoUnderScoreSpecificationRules pos Set.empty Map.empty mp fun (FunctionAnnotation (map snd args) (AnnotationLiteral "_"))
                    case substituteVariables pos (Set.unions $ map (collectGenenrics mp . snd) args) rels specificationRules mp ret' of
                        Left a -> return . Left $ "Could not infer the return type: " ++ a ++ "\n" ++ showPos pos
                        Right inferredRetType ->
                            let spfun = makeFunAnnotation args inferredRetType in
                            case getSpecificationRules pos Set.empty base mp fun spfun of
                                Left err -> return $ Left err
                                Right res -> 
                                    let 
                                        a = Set.fromList (Map.keys (Map.filterWithKey (\a b -> isGenericAnnotation a && not (sameTypesBool pos mp a b)) res))
                                        b = Set.fromList (Map.keys (Map.filterWithKey (\a b -> isGenericAnnotation a && not (sameTypesBool pos mp a b)) base))
                                    in
                                    if a == b then 
                                        Right <$> insertAnnotation lhs (Finalizeable True (OpenFunctionAnnotation anns ret' ft $ implft:impls))
                                    else return . Left $ "Forbidden to specify specified type variables\n" ++ showPos pos
                Left err -> return $ Left err
        Right a -> return . Left $ "Cannot extend function " ++ show a ++ "\n" ++ showPos pos
getAssumptionType (CastNode lhs ann _) = Right <$> (insertAnnotation lhs (Finalizeable False ann) $> AnnotationLiteral "Bool")
getAssumptionType (RemoveFromUnionNode lhs ann pos) =
    (\case
        Right a@TypeUnion{} -> (return . Right $ AnnotationLiteral "Bool") <$ (\x -> insertAnnotation lhs . Finalizeable False) =<< excludeFromUnion pos ann a
        Right a@NewTypeInstanceAnnotation{} -> (return . Right $ AnnotationLiteral "Bool") <$ (\x -> insertAnnotation lhs . Finalizeable False) =<< excludeFromUnion pos ann a
        Right a -> return . Left $ expectedUnion pos lhs ann
        Left err -> return $ Left err) =<< getAnnotationState lhs
getAssumptionType (DeclN (Expr n)) = getAssumptionType n
getAssumptionType (Return n pos) = getAssumptionType n >>= \x -> makeUnionIfNotSame pos x (getAnnotationState lhs) lhs
    where lhs = LhsIdentifer "return" pos
getAssumptionType (IfStmnt (RemoveFromUnionNode lhs ann _) ts es pos) = do
    (_, (_, mp)) <- get
    pushScope
    typLhs <- getAnnotationState lhs
    case typLhs of
        Right t@TypeUnion{} -> excludeType t
        Right t@NewTypeInstanceAnnotation{} -> excludeType t
        _ -> return . Left $ expectedUnion pos lhs typLhs
    where excludeType t = do
            xs <- excludeFromUnion pos ann t
            case xs of
                Right ann' -> do
                    insertAnnotation lhs $ Finalizeable False ann'
                    t <- sequence <$> mapM getAssumptionType ts
                    popScope
                    pushScope
                    insertAnnotation lhs (Finalizeable False ann)
                    e <- sequence <$> mapM getAssumptionType es
                    popScope
                    let res = case (t, e) of
                            (Right b, Right c) -> Right $ AnnotationLiteral "_"
                            (Left a, _) -> Left a
                            (_, Left a) -> Left a
                    return res
                Left err -> return $ Left err
getAssumptionType (IfStmnt (CastNode lhs ann _) ts es pos) = do
    mp <- getTypeMap
    pushScope
    insertAnnotation lhs (Finalizeable False ann)
    t <- sequence <$> mapM getAssumptionType ts
    popScope
    pushScope
    typLhs <- getAnnotationState lhs
    case typLhs of
        Right ts@TypeUnion{} -> do
            remAnn <- excludeFromUnion pos ann ts
            case remAnn of
                Right remAnn -> insertAnnotation lhs $ Finalizeable False remAnn
                Left _ -> return ann
        _ -> return ann
    e <- sequence <$> mapM getAssumptionType es
    popScope
    let res = case (t, e) of
            (Right b, Right c) -> Right $ AnnotationLiteral "_"
            (Left a, _) -> Left a
            (_, Left a) -> Left a
    return res
getAssumptionType (IfStmnt cond ts es pos) = do
    (_, (_, mp)) <- get
    c <- consistentTypes cond
    case sameTypes pos mp (AnnotationLiteral "Bool") <$> c of
        Right _ -> do
            pushScope
            t <- sequence <$> mapM getAssumptionType ts
            popScope
            pushScope
            e <- sequence <$> mapM getAssumptionType es
            popScope
            let res = case (c, t, e) of
                    (Right a, Right b, Right c) -> Right $ AnnotationLiteral "_"
                    (Left a, _, _) -> Left a
                    (_, Left a, _) -> Left a
                    (_, _, Left a) -> Left a
            return res
        Left err -> return $ Left err
getAssumptionType (IfExpr c t e pos) =
    (\tx ex mp -> mergedTypeConcrete pos mp <$> tx <*> ex) <$> getAssumptionType t <*> getAssumptionType e <*> getTypeMap
getAssumptionType (FunctionDef args ret body pos) = 
    case ret of
        Just ret -> return . Right $ makeFunAnnotation args ret
        Nothing -> do
            whole_old_ans@(a, ((i, old_ans), mp)) <- get
            let program = Program body
            let ans = (a, ((i, assumeProgramMapping program i (Annotations (Map.fromList $ (LhsIdentifer "return" pos, Finalizeable False $ AnnotationLiteral "_"):map (second (Finalizeable True . rigidizeTypeVariables mp)) args) (Just old_ans)) mp), mp))
            put ans
            mapM_ getAssumptionType body
            (new_ans, _) <- gets snd
            x <- firstInferrableReturn pos body
            case x of
                Right ret -> do
                    typ <- getAnnotationState $ LhsIdentifer "return" pos
                    let ntyp = typ >>= (\c -> 
                            if c then maybe typ Right . matchingUserDefinedType pos Set.empty (Map.filter isStructOrUnionOrFunction mp) =<< typ 
                            else typ
                            ) . isSearchable
                    put whole_old_ans
                    return (makeFunAnnotation args . unrigidizeTypeVariables mp <$> ntyp)
                Left err -> return . Left $ err
    where
        isSearchable Annotation{} = False
        isSearchable AnnotationLiteral{} = False
        isSearchable NewTypeInstanceAnnotation{} = False
        isSearchable NewTypeAnnotation{} = False
        isSearchable OpenFunctionAnnotation{} = False
        isSearchable GenericAnnotation{} = False
        isSearchable _ = True

        isStructOrUnionOrFunction TypeUnion{} = True
        isStructOrUnionOrFunction StructAnnotation{} = True
        isStructOrUnionOrFunction FunctionAnnotation{} = True
        isStructOrUnionOrFunction _ = False
getAssumptionType (Call e args pos) = (\case
                    Right fann@(FunctionAnnotation fargs ret) -> do
                        mp <- getTypeMap
                        anns <- sequence <$> mapM consistentTypes args
                        case anns of
                            Right anns -> let 
                                defs = Set.unions $ map (collectGenenrics mp) anns
                                (spec, rel) = getPartialNoUnderScoreSpecificationRules pos defs Map.empty mp fann (FunctionAnnotation anns (AnnotationLiteral "_")) in
                                case substituteVariables pos defs rel spec mp ret of
                                    Right ret' -> case specify pos defs Map.empty mp fann (FunctionAnnotation anns ret') of
                                        Right _ -> return $ Right ret'
                                        Left err -> return $ Left err
                                    Left err -> return $ Left err
                            Left err -> return $ Left err
                    Right opf@(OpenFunctionAnnotation oanns oret ft impls) -> do
                        mp <- getTypeMap
                        anns <- sequence <$> mapM consistentTypes args
                        case anns of
                            Right anns -> let 
                                defs = Set.unions $ map (collectGenenrics mp) anns
                                (spec, rel) = getPartialNoUnderScoreSpecificationRules pos defs Map.empty mp (FunctionAnnotation oanns oret) (FunctionAnnotation anns (AnnotationLiteral "_")) in
                                case substituteVariables pos defs rel spec mp oret of
                                    Right ret' -> case getSpecificationRules pos defs Map.empty mp (FunctionAnnotation oanns oret) (FunctionAnnotation anns ret') of
                                        Right base -> case Map.lookup ft base of
                                            Just a -> maybe 
                                                    (return . Left $ "Could find instance " ++ show opf ++ " for " ++ show a ++ "\n" ++ showPos pos) 
                                                    (const . return $ Right ret')
                                                    (find (\b -> specifyTypesBool pos defs base mp b a) impls)
                                            Nothing -> return . Left $ "The argument does not even once occur in the whole method\n" ++ showPos pos
                                        Left err -> return $ Left err
                                    Left err -> return $ Left err
                            Left err -> return $ Left err       
                    Right ann -> return . Left $ "Can't call a value of type " ++ show ann ++ "\n" ++ showPos pos
                    Left err -> return $ Left err) =<< getTypeStateFrom (getAssumptionType e) pos
getAssumptionType (StructN (Struct ns _)) = 
        (\xs -> mapRight 
            (return . Right $ AnnotationLiteral "_") 
            (const . return $ StructAnnotation <$> sequence xs)) =<< mapM getAssumptionType ns
getAssumptionType (Access st p pos) = do
    mp <- getTypeMap
    f mp =<< getTypeStateFrom (consistentTypes st) pos where 

    f :: UserDefinedTypes -> Either String Annotation -> AnnotationState (Annotations (Finalizeable Annotation)) (Either String Annotation)
    f mp = \case
            Right g@(GenericAnnotation _ cns) -> return $ genericHas pos g p cns
            Right g@(RigidAnnotation _ cns) -> return $ genericHas pos g p cns
            Right (TypeUnion st) -> ((\x -> head <$> mapM (sameTypes pos mp (head x)) x) =<<) <$> x where 
                x = sequence <$> mapM (\x -> f mp =<< getTypeState x pos) stl
                stl = Set.toList st
            Right (NewTypeInstanceAnnotation id anns) -> 
                accessNewType anns
                (\(NewTypeAnnotation _ _ ps) -> return $ toEither ("Could not find " ++ show p ++ " in " ++ show ps ++ "\n" ++ showPos pos) (Map.lookup p ps)) 
                (LhsIdentifer id pos)
            Right (StructAnnotation ps) -> return $ toEither ("Could not find " ++ show p ++ " in " ++ show ps ++ "\n" ++ showPos pos) (Map.lookup p ps)
            Right a -> return . Left $ "Cannot get " ++ show p ++ " from type " ++ show a ++ "\n" ++ showPos pos
            Left err -> return $ Left err
getAssumptionType (Lit (LitInt _ _)) = return . Right $ AnnotationLiteral "Int"
getAssumptionType (Lit (LitBool _ _)) = return . Right $ AnnotationLiteral "Bool"
getAssumptionType (Lit (LitString _ _)) = return . Right $ AnnotationLiteral "String"
getAssumptionType (Identifier x pos) = do
    ann <- getAnnotationState (LhsIdentifer x pos)
    case ann of
        Right a -> return $ Right a
        Left err  -> return $ Left err
getAssumptionType n = error $ "No arument of the follwoing type expected " ++ show n

genericHas pos g givenLhs [] = Left $ "Could not find " ++ show givenLhs ++ " in " ++ show g ++ "\n" ++ showPos pos
genericHas pos g givenLhs ((ConstraintHas lhs (AnnotationConstraint ann)):xs) = if lhs == givenLhs then Right ann else genericHas pos g givenLhs xs

makeAssumptions :: State (Annotation, b) a -> b -> b
makeAssumptions s m = snd $ execState s (AnnotationLiteral "_", m)

assumeProgramMapping :: Program -> Int -> Annotations (Finalizeable Annotation) -> UserDefinedTypes -> Annotations (Finalizeable Annotation)
assumeProgramMapping (Program xs) i anns mp = snd . fst $ makeAssumptions (mapM getAssumptionType $ filter nonDecls xs) ((i, anns), mp)

nonDecls (DeclN Decl{}) = True
nonDecls (DeclN FunctionDecl{}) = True
nonDecls (DeclN Assign{}) = True
nonDecls _ = False

sourcePos = SourcePos "core" (mkPos 0) (mkPos 0)

baseMapping = Map.fromList $ map (second (Finalizeable True)) [
    (LhsIdentifer "add" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (GenericAnnotation "a" []) (GenericAnnotation "a" []) [AnnotationLiteral "Int", AnnotationLiteral "String"]),
    (LhsIdentifer "println" sourcePos, FunctionAnnotation [GenericAnnotation "a" []] (GenericAnnotation "a" [])),
    (LhsIdentifer "duplicate" sourcePos, FunctionAnnotation [GenericAnnotation "a" []] (GenericAnnotation "a" [])),
    (LhsIdentifer "write" sourcePos, FunctionAnnotation [GenericAnnotation "a" []] (StructAnnotation Map.empty)),
    (LhsIdentifer "concat" sourcePos, FunctionAnnotation [TypeUnion (Set.fromList [Annotation "Nil",NewTypeInstanceAnnotation "Array" [GenericAnnotation "a" []]]),TypeUnion (Set.fromList [Annotation "Nil",NewTypeInstanceAnnotation "Array" [GenericAnnotation "b" []]])] (TypeUnion (Set.fromList [Annotation "Nil",NewTypeInstanceAnnotation "Array" [TypeUnion (Set.fromList [GenericAnnotation "a" [],GenericAnnotation "b" []])]]))),
    (LhsIdentifer "sub" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (GenericAnnotation "a" []) (GenericAnnotation "a" []) [AnnotationLiteral "Int"]),
    (LhsIdentifer "mod" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (GenericAnnotation "a" []) (GenericAnnotation "a" []) [AnnotationLiteral "Int"]),
    (LhsIdentifer "mul" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (GenericAnnotation "a" []) (GenericAnnotation "a" []) [AnnotationLiteral "Int"]),
    (LhsIdentifer "div" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (GenericAnnotation "a" []) (GenericAnnotation "a" []) [AnnotationLiteral "Int"]),
    (LhsIdentifer "gt" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (AnnotationLiteral "Bool") (GenericAnnotation "a" []) [AnnotationLiteral "Int"]),
    (LhsIdentifer "gte" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (AnnotationLiteral "Bool") (GenericAnnotation "a" []) [AnnotationLiteral "Int"]),
    (LhsIdentifer "lt" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (AnnotationLiteral "Bool") (GenericAnnotation "a" []) [AnnotationLiteral "Int"]),
    (LhsIdentifer "lte" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (AnnotationLiteral "Bool") (GenericAnnotation "a" []) [AnnotationLiteral "Int"]),
    (LhsIdentifer "eq" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (AnnotationLiteral "Bool") (GenericAnnotation "a" []) [AnnotationLiteral "Int", AnnotationLiteral "Bool", AnnotationLiteral "String"]),
    (LhsIdentifer "neq" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (AnnotationLiteral "Bool") (GenericAnnotation "a" []) [AnnotationLiteral "Int", AnnotationLiteral "Bool", AnnotationLiteral "String"]),
    (LhsIdentifer "anded" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (AnnotationLiteral "Bool") (GenericAnnotation "a" []) [AnnotationLiteral "Bool"]),
    (LhsIdentifer "ored" sourcePos, OpenFunctionAnnotation [GenericAnnotation "a" [], GenericAnnotation "a" []] (AnnotationLiteral "Bool") (GenericAnnotation "a" []) [AnnotationLiteral "Bool"]),
    (LhsIdentifer "not" sourcePos, FunctionAnnotation [AnnotationLiteral "Bool"] (AnnotationLiteral "Bool")),
    (LhsIdentifer "neg" sourcePos, FunctionAnnotation [AnnotationLiteral "Int"] (AnnotationLiteral "Int"))
    ]

assumeProgram prog i = assumeProgramMapping prog i (Annotations Map.empty (Just $ Annotations baseMapping Nothing))

showPos :: SourcePos -> String
showPos (P.SourcePos s ln cn) = 
    "In file: " ++ s ++ ", at line: " ++ tail (dropWhile (/= ' ') (show ln)) ++ ", at colounm: " ++ tail (dropWhile (/= ' ') (show cn))

noTypeFound expected pos = "No type named " ++ expected ++ " found\n" ++ showPos pos
unmatchedType a b pos = "Can't match expected type " ++ show a ++ " with given type " ++ show b ++ "\n" ++ showPos pos

unionFrom :: Annotation -> Annotation -> Either a b -> Annotation
unionFrom a b x = 
    case x of
        Right _ -> b
        Left err -> createUnion a b

mergedTypeConcrete = mergedType (True, False, Map.empty) comparisionEither

mergedType :: (Bool, Bool, Map.Map String [Constraint]) -> ComparisionReturns String Annotation -> P.SourcePos -> UserDefinedTypes -> Annotation -> Annotation -> Annotation
mergedType _ crt pos _ a@AnnotationLiteral{} b@AnnotationLiteral{} = 
    if a == b then a else createUnion a b
mergedType gs crt pos mp a@(FunctionAnnotation as ret1) b@(FunctionAnnotation bs ret2) = 
    if length as == length bs then FunctionAnnotation (init ls) (last ls)
    else createUnion a b
    where ls = zipWith (mergedType gs crt pos mp) (as ++ [ret1]) (bs ++ [ret2])
mergedType gs crt pos mp a@(NewTypeInstanceAnnotation e1 as1) b@(NewTypeInstanceAnnotation e2 as2)
    | e1 == e2 && length as1 == length as2 = NewTypeInstanceAnnotation e1 ls
    | otherwise = createUnion a b
    where ls = zipWith (mergedType gs crt pos mp) as1 as2
mergedType gs crt pos mp a@(StructAnnotation ps1) b@(StructAnnotation ps2)
    | Map.empty == ps1 || Map.empty == ps2 = if ps1 == ps2 then a else createUnion a b
    | Map.size ps1 /= Map.size ps2 = createUnion a b
    | isJust $ sequence ls = maybe (createUnion a b) StructAnnotation (sequence ls)
    | otherwise = createUnion a b
    where
        ls = Map.mapWithKey (f ps1) ps2
        f ps2 k v1 = 
            case Map.lookup k ps2 of
                Just v2
                    -> case sameTypesGenericCrt gs crt pos mp v1 v2 of
                        Right a -> Just a
                        Left err -> Nothing
                Nothing -> Nothing
mergedType gs crt pos mp a@(TypeUnion as) b@(TypeUnion bs) = do
    case mapM_ (f mp $ Set.toList as) (Set.toList bs) of
        Right () -> foldr1 (mergedType gs crt pos mp) (Set.toList bs)
        Left _ -> case createUnion a b of
            TypeUnion xs -> foldr1 (mergedType gs crt pos mp) $ Set.toList $ Set.map (mergeUnions xs) xs
            a -> a
    where
        mergeUnions xs a = foldr1 (mergedType gs crt pos mp) $ filter (predicate a) nxs where nxs = Set.toList xs
        predicate a b = isRight (sameTypesGenericCrt gs crt pos mp a b) || isRight (sameTypesGenericCrt gs crt pos mp b a)
        f mp ps2 v1 = join $ getFirst a b pos $ map (\x -> success crt <$> sameTypesGenericCrt gs crt pos mp x v1) ps2
mergedType gs crt pos mp a@(TypeUnion st) b = 
    case fromJust $ getFirst a b pos $ map (\x -> Just $ sameTypesGenericCrt gs crt pos mp x b) $ Set.toList st of
        Right _ -> a
        Left _ -> createUnion a b
mergedType gs crt pos mp a b@(TypeUnion st) = mergedType gs crt pos mp b a
mergedType gs crt pos mp (Annotation id1) b@(Annotation id2)
    | id1 == id2 = b
    | otherwise = case Map.lookup (LhsIdentifer id1 pos) mp of
        Just a -> case Map.lookup (LhsIdentifer id2 pos) mp of
            Just b -> unionFrom a b $ sameTypesGenericCrt gs crt pos mp a b
mergedType gs crt pos mp (Annotation id) b = 
    case Map.lookup (LhsIdentifer id pos) mp of
        Just a -> unionFrom a b $ sameTypesGenericCrt gs crt pos mp a b
mergedType gs crt pos mp b (Annotation id) = 
    case Map.lookup (LhsIdentifer id pos) mp of
        Just a -> unionFrom a b $ sameTypesGenericCrt gs crt pos mp a b
mergedType tgs@(_, sensitive, gs) crt pos mp a@(GenericAnnotation id1 cs1) b@(GenericAnnotation id2 cs2)
    | sensitive && id1 `Map.member` gs && id2 `Map.member` gs && id1 /= id2 = createUnion a b
    | otherwise = if id1 == id2 then unionFrom a b $ zipWithM (matchConstraint tgs crt pos mp) cs1 cs2 *> success crt a else createUnion a b
mergedType tgs@(_, sensitive, gs) crt pos mp a@(GenericAnnotation _ acs) b = 
    if sensitive then 
        unionFrom a b $ mapM (matchConstraint tgs crt pos mp (AnnotationConstraint b)) acs
    else createUnion a b
mergedType tgs@(_, sensitive, gs) crt pos mp b a@(GenericAnnotation _ acs) = 
    if sensitive then 
        unionFrom a b $ mapM (matchConstraint tgs crt pos mp (AnnotationConstraint b)) acs *> success crt a
    else createUnion a b
mergedType (considerUnions, sensitive, gs) crt pos mp ft@(OpenFunctionAnnotation anns1 ret1 forType impls) (OpenFunctionAnnotation anns2 ret2 _ _) =
    OpenFunctionAnnotation (init ls) (last ls) forType impls where 
        ls = zipWith (mergedType (considerUnions, sensitive, gs') crt pos mp) (anns1 ++ [ret1]) (anns2 ++ [ret2])
        gs' = genericsFromList (anns1 ++ [ret1]) `Map.union` gs 
mergedType (considerUnions, sensitive, gs) crt pos mp a@(OpenFunctionAnnotation anns1 ret1 _ _) (FunctionAnnotation args ret2) = 
    FunctionAnnotation (init ls) (last ls) where
        ls = zipWith (mergedType (considerUnions, sensitive, gs') crt pos mp) (anns1 ++ [ret1]) (args ++ [ret2])
        gs' = genericsFromList (anns1 ++ [ret1]) `Map.union` gs
mergedType gs crt pos mp a@(RigidAnnotation id1 _) b@(RigidAnnotation id2 _) 
    | id1 == id2 = a
    | otherwise = createUnion a b
mergedType _ crt pos _ a b = createUnion a b

sameTypesGenericCrt :: (Bool, Bool, Map.Map String [Constraint]) -> ComparisionReturns String Annotation -> P.SourcePos -> UserDefinedTypes -> Annotation -> Annotation -> Either String Annotation
sameTypesGenericCrt _ crt pos _ a@AnnotationLiteral{} b@AnnotationLiteral{} = 
    if a == b then success crt a else failout crt a b pos
sameTypesGenericCrt gs crt pos mp a@(FunctionAnnotation as ret1) b@(FunctionAnnotation bs ret2) = 
    if length as == length bs then (\xs -> FunctionAnnotation (init xs) (last xs)) <$> ls
    else failout crt a b pos
    where ls = zipWithM (sameTypesGenericCrt gs crt pos mp) (as ++ [ret1]) (bs ++ [ret2])
sameTypesGenericCrt gs crt pos mp a@(NewTypeAnnotation id1 anns1 _) b@(NewTypeInstanceAnnotation id2 anns2) 
    | id1 /= id2 = Left $ unmatchedType a b pos
    | otherwise = sameTypesGenericCrt gs crt pos mp (NewTypeInstanceAnnotation id1 anns1) b
sameTypesGenericCrt gs crt pos mp a@(NewTypeInstanceAnnotation e1 as1) b@(NewTypeInstanceAnnotation e2 as2)
    | e1 == e2 && length as1 == length as2 = NewTypeInstanceAnnotation e1 <$> ls
    | e1 == e2 && length as1 < length as2 = flip (sameTypesGenericCrt gs crt pos mp) b =<< fullAnotationFromInstanceFree pos mp a
    | otherwise = failout crt a b pos 
    where ls = zipWithM (sameTypesGenericCrt gs crt pos mp) as1 as2
sameTypesGenericCrt gs crt pos mp a@(StructAnnotation ps1) b@(StructAnnotation ps2)
    | Map.empty == ps1 || Map.empty == ps2 = if ps1 == ps2 then success crt a else failout crt a b pos
    | Map.size ps1 /= Map.size ps2 = failout crt a b pos
    | isJust $ sequence ls = maybe (failout crt a b pos) (success crt) (StructAnnotation <$> sequence ls)
    | otherwise = failout crt a b pos
    where
        ls = Map.mapWithKey (f ps1) ps2
        f ps2 k v1 = 
            case Map.lookup k ps2 of
                Just v2
                    -> case sameTypesGenericCrt gs crt pos mp v1 v2 of
                        Right a -> Just a
                        Left err -> Nothing
                Nothing -> Nothing
sameTypesGenericCrt gs crt pos mp a@(TypeUnion as) b@(TypeUnion bs) = do
    case mapM (f mp $ Set.toList as) (Set.toList bs) of
        Right s -> success crt $ TypeUnion $ Set.fromList s
        Left err -> failiure crt err
    where
        f mp ps2 v1 = fromJust $ getFirst a b pos $ map (\x -> Just $ sameTypesGenericCrt gs crt pos mp x v1) ps2
sameTypesGenericCrt tgs@(considerUnions, _, _) crt pos mp a@(TypeUnion st) b
    | considerUnions =
        fromJust $ getFirst a b pos $ map (\x -> Just $ sameTypesGenericCrt tgs crt pos mp x b) $ Set.toList st
    | otherwise = Left $ unmatchedType a b pos
sameTypesGenericCrt tgs@(considerUnions, _, _) crt pos mp b a@(TypeUnion st) 
    | considerUnions =
        fromJust $ getFirst a b pos $ map (\x -> Just $ sameTypesGenericCrt tgs crt pos mp x b) $ Set.toList st
    | otherwise = Left $ unmatchedType a b pos
sameTypesGenericCrt gs crt pos mp (Annotation id1) b@(Annotation id2)
    | id1 == id2 = success crt b
    | otherwise = case Map.lookup (LhsIdentifer id1 pos) mp of
        Just a -> case Map.lookup (LhsIdentifer id2 pos) mp of
            Just b -> sameTypesGenericCrt gs crt pos mp a b
            Nothing -> failiure crt $ noTypeFound id2 pos
        Nothing -> failiure crt $ noTypeFound id1 pos
sameTypesGenericCrt gs crt pos mp (Annotation id) b = 
    case Map.lookup (LhsIdentifer id pos) mp of
        Just a -> sameTypesGenericCrt gs crt pos mp a b
        Nothing -> failiure crt $ noTypeFound id pos
sameTypesGenericCrt gs crt pos mp b (Annotation id) = 
    case Map.lookup (LhsIdentifer id pos) mp of
        Just a -> sameTypesGenericCrt gs crt pos mp a b
        Nothing -> failiure crt $ noTypeFound id pos
sameTypesGenericCrt tgs@(_, sensitive, gs) crt pos mp a@(GenericAnnotation id1 cs1) b@(GenericAnnotation id2 cs2)
    | sensitive && id1 `Map.member` gs && id2 `Map.member` gs && id1 /= id2 = Left $ "Expected " ++ show a ++ " but got " ++ show b
    | otherwise = if id1 == id2 then zipWithM (matchConstraint tgs crt pos mp) cs1 cs2 *> success crt a else failout crt a b pos
sameTypesGenericCrt gs crt pos mp a@(GenericAnnotation id1 cs1) b@(RigidAnnotation id2 cs2) = sameTypesGenericCrt gs crt pos mp (RigidAnnotation id1 cs1) (RigidAnnotation id2 cs2) $> b
sameTypesGenericCrt gs crt pos mp a@(RigidAnnotation id1 cs1) b@(GenericAnnotation id2 cs2) = sameTypesGenericCrt gs crt pos mp (RigidAnnotation id1 cs1) (RigidAnnotation id2 cs2) $> b
sameTypesGenericCrt tgs@(_, sensitive, gs) crt pos mp a@(RigidAnnotation id1 cs1) b@(RigidAnnotation id2 cs2)
    | id1 == id2 = zipWithM (matchConstraint tgs crt pos mp) cs1 cs2 *> success crt a 
    | otherwise = failout crt a b pos
sameTypesGenericCrt tgs@(_, sensitive, gs) crt pos mp a@(GenericAnnotation _ acs) b = 
    if sensitive then 
        mapM (matchConstraint tgs crt pos mp (AnnotationConstraint b)) acs *> success crt b
    else Left $ unmatchedType a b pos
sameTypesGenericCrt tgs@(_, sensitive, gs) crt pos mp b a@(GenericAnnotation _ acs) = 
    if sensitive then 
        mapM (matchConstraint tgs crt pos mp (AnnotationConstraint b)) acs *> success crt a
    else Left $ unmatchedType a b pos
sameTypesGenericCrt (considerUnions, sensitive, gs) crt pos mp ft@(OpenFunctionAnnotation anns1 ret1 forType impls) (OpenFunctionAnnotation anns2 ret2 _ _) =
    (\xs -> OpenFunctionAnnotation (init xs) (last xs) forType impls) <$> ls where 
        ls = zipWithM (sameTypesGenericCrt (considerUnions, sensitive, gs') crt pos mp) (anns1 ++ [ret1]) (anns2 ++ [ret2])
        gs' = genericsFromList (anns1 ++ [ret1]) `Map.union` gs 
sameTypesGenericCrt (considerUnions, sensitive, gs) crt pos mp a@(OpenFunctionAnnotation anns1 ret1 _ _) (FunctionAnnotation args ret2) = 
    (\xs -> FunctionAnnotation (init xs) (last xs)) <$> ls where
        ls = zipWithM (sameTypesGenericCrt (considerUnions, sensitive, gs') crt pos mp) (anns1 ++ [ret1]) (args ++ [ret2])
        gs' = genericsFromList (anns1 ++ [ret1]) `Map.union` gs
sameTypesGenericCrt _ crt pos _ a b = failout crt a b pos

genericsFromList :: [Annotation] -> Map.Map String [Constraint]
genericsFromList anns = foldr1 Map.union (map getGenerics anns)

matchConstraint :: (Bool, Bool, Map.Map String [Constraint]) -> ComparisionReturns String Annotation -> SourcePos -> UserDefinedTypes -> Constraint -> Constraint -> Either String Constraint
matchConstraint gs crt pos mp c@(AnnotationConstraint a) (AnnotationConstraint b) = c <$ sameTypesGenericCrt gs crt pos mp a b
matchConstraint gs crt pos mp a@(ConstraintHas lhs cns) b@(AnnotationConstraint ann) = 
    case ann of
        StructAnnotation ds -> 
            if lhs `Map.member` ds then Right b
            else Left $ "Can't match " ++ show a ++ " with " ++ show b
        _ -> Left $ "Can't match " ++ show a ++ " with " ++ show b
matchConstraint gs crt pos mp c@(ConstraintHas a c1) (ConstraintHas b c2) = 
    if a /= b then Left $ "Can't match constraint " ++ show a ++ " with constraint " ++ show b ++ "\n" ++ showPos pos
    else c <$ matchConstraint gs crt pos mp c1 c2
matchConstraint gs crt pos mp a@(AnnotationConstraint ann) b@(ConstraintHas lhs cns) = matchConstraint gs crt pos mp b a

getGenerics :: Annotation -> Map.Map String [Constraint]
getGenerics (GenericAnnotation id cons) = Map.singleton id cons
getGenerics (OpenFunctionAnnotation anns ret _ _) = foldr1 Map.union (map getGenerics $ ret:anns)
getGenerics _ = Map.empty

comparisionEither :: ComparisionReturns String Annotation
comparisionEither = ComparisionReturns {
    success = Right,
    failiure = Left,
    failout = \a b pos -> Left $ unmatchedType a b pos
}

unionEither :: ComparisionReturns String Annotation
unionEither = ComparisionReturns {
    success = Right,
    failiure = Left,
    failout = \a b _ -> Right $ createUnion a b
}

createUnion a b = go a b where
    go (TypeUnion s1) (TypeUnion s2) = TypeUnion $ s1 `Set.union` s2
    go (TypeUnion s1) a = TypeUnion $ a `Set.insert` s1
    go a (TypeUnion s1) = TypeUnion $ a `Set.insert` s1
    go a b = TypeUnion $ Set.fromList [a, b]

sameTypesGeneric a = sameTypesGenericCrt a comparisionEither

sameTypes :: SourcePos -> UserDefinedTypes -> Annotation -> Annotation -> Either String Annotation
sameTypes = sameTypesGeneric (True, False, Map.empty)

getTypeMap :: State (a, (b, c)) c
getTypeMap = gets (snd . snd)

excludeFromUnion :: P.SourcePos -> Annotation -> Annotation -> AnnotationState a (Either String Annotation)
excludeFromUnion pos a (TypeUnion ts) = do
    (_, (_, usts)) <- get
    if Set.size ts == 1 then excludeFromUnion pos a $ Set.elemAt 0 ts else do
        let (unions, simples) = partition isUnion . Set.toList . Set.map snd . Set.filter pred $ Set.map (\b -> (any isRight [sameTypes pos usts b a, sameTypes pos usts a b], b)) ts 
        unions' <- sequence <$> mapM (excludeFromUnion pos a) unions
        case (\x -> Set.fromList $ x ++ simples) <$> unions' of
            Right xs -> if Set.null xs then 
                    return . Left $ "No set matching predicate notis " ++ show a ++ "\n" ++ showPos pos
                else return . Right $ foldr1 (mergedTypeConcrete pos usts) xs
            Left err -> return $ Left err
    where 
        pred (b, v) = (isUnion v && b) || not b
        isUnion = makeImpl True False
excludeFromUnion pos a@(NewTypeInstanceAnnotation id1 anns1) b@(NewTypeInstanceAnnotation id2 anns2)
    | id1 /= id2 = return . Left $ expectedUnion pos a b
    | otherwise = do
        (_, (_, usts)) <- get
        (\case
            Right xs -> return . Right $ NewTypeInstanceAnnotation id1 xs
            Left err -> return $ Left err) . sequence =<< zipWithM (excludeFromUnion pos) anns1 anns2
excludeFromUnion pos a b = return $ Right b

accessNewType givenArgs f fid@(LhsIdentifer id pos) =
    (\case
        Right x -> f x
        Left err -> return . Left $ err) =<< getFullAnnotation fid givenArgs
accessNewType _ _ _ = error "Only unions allowed"

fullAnotationFromInstance pos (NewTypeInstanceAnnotation id args) = getFullAnnotation (LhsIdentifer id pos) args
fullAnotationFromInstance a b = error $ "Unexpected argments for isGeneralizedInstance [" ++ show a ++ ", " ++ show b ++ "]"

fullAnotationFromInstanceFree pos mp (NewTypeInstanceAnnotation id givenArgs) = 
    case Map.lookup fid mp of
        Just x@(NewTypeAnnotation id args map) -> 
            substituteVariablesOptFilter False pos (f mp) Map.empty (Map.fromList $ zip args givenArgs) mp x
        Just a -> Left $ noTypeFound id pos
        Nothing -> Left $ noTypeFound id pos
    where 
        f mp = Set.unions $ map (collectGenenrics mp) givenArgs
        fid = LhsIdentifer id pos
fullAnotationFromInstanceFree a b c = error $ "Unexpected argments for isGeneralizedInstance [" ++ show a ++ ", " ++ show b ++ ", " ++ show c ++ "]"

getFullAnnotation fid@(LhsIdentifer id pos) givenArgs = do
    mp <- getTypeMap
    case Map.lookup fid mp of
        Just x@(NewTypeAnnotation id args map) -> 
            return $ substituteVariablesOptFilter False pos (f mp) Map.empty (Map.fromList $ zip args givenArgs) mp x
        Just a -> return . Left $ noTypeFound id pos
        Nothing -> return . Left $ noTypeFound id pos
    where f mp = Set.unions $ map (collectGenenrics mp) givenArgs
getFullAnnotation a b = error $ "Unexpected argments for getFullAnnotation [" ++ show a ++ ", " ++ show b ++ "]"

modifyAccess mp pos acc whole expected given prop access accPos f = case whole of
        g@(GenericAnnotation _ cns) -> return $ genericHas pos g prop cns
        g@(RigidAnnotation _ cns) -> return $ genericHas pos g prop cns
        TypeUnion{} -> f (Access access prop accPos) >>= \res -> return $ sameTypes pos mp given =<< res
        NewTypeInstanceAnnotation{} -> f (Access access prop accPos) >>= \res -> return $ sameTypes pos mp given =<< res
        StructAnnotation ps -> case sameTypesImpl given pos mp expected given of 
            Right a -> return $ Right a
            Left err -> Right <$> modifyWhole (listAccess acc) whole (mergedTypeConcrete pos mp expected given)
        a -> return . Left $ "Cannot get " ++ show prop ++ " from type " ++ show a ++ "\n" ++ showPos pos

consistentTypesPass :: ConsistencyPass -> Node -> AnnotationState (Annotations (Finalizeable Annotation)) (Either String Annotation)
consistentTypesPass VerifyAssumptions (DeclN (Decl lhs rhs _ pos)) = (\a b m -> mergedTypeConcrete pos m <$> a <*> b)
    <$> getAnnotationState lhs <*> consistentTypesPass VerifyAssumptions rhs <*> getTypeMap
consistentTypesPass RefineAssumtpions (DeclN (Decl lhs rhs _ pos)) = consistentTypesPass RefineAssumtpions rhs >>= \x -> makeUnionIfNotSame pos x (getAnnotationState lhs) lhs
consistentTypesPass VerifyAssumptions (DeclN (Assign (LhsAccess access prop accPos) rhs pos)) = (\a b m -> join $ sameTypes pos m <$> a <*> b)
    <$> getAssumptionType (Access access prop accPos) <*> consistentTypesPass VerifyAssumptions rhs <*> getTypeMap
consistentTypesPass RefineAssumtpions (DeclN (Assign lhs@(LhsAccess access prop accPos) rhs pos)) =
    do
        expcd <- consistentTypesPass RefineAssumtpions (Access access prop accPos)
        rhs <- getTypeStateFrom (consistentTypesPass RefineAssumtpions rhs) pos
        full <- getTypeStateFrom (getAnnotationState $ initIdentLhs lhs) pos
        mp <- getTypeMap
        case (full, expcd, rhs) of
            (Right whole, Right expcd, Right rhs) ->
                case sameTypesImpl rhs pos mp expcd rhs of
                    Right a -> return $ Right a
                    Left _ -> do
                        x <- modifyAccess mp pos (Access access prop accPos) whole expcd rhs prop access accPos (consistentTypesPass RefineAssumtpions)
                        case x of
                            Right x -> modifyAnnotationState (initIdentLhs lhs) x
                            Left err -> return $ Left err
            (Left err, _, _) -> return $ Left err
            (_, Left err, _) -> return $ Left err
            (_, _, Left err) -> return $ Left err
consistentTypesPass VerifyAssumptions (DeclN (Assign lhs rhs pos)) = (\a b m -> mergedTypeConcrete pos m <$> a <*> b) 
    <$> getAnnotationState lhs <*> consistentTypesPass VerifyAssumptions rhs <*> getTypeMap
consistentTypesPass RefineAssumtpions (DeclN (Assign lhs rhs pos)) = getAssumptionType rhs >>= \x -> makeUnionIfNotSame pos x (getAnnotationState lhs) lhs
consistentTypesPass p (DeclN (FunctionDecl lhs ann pos)) = do
    m <- getTypeMap
    l <- getAnnotationState lhs
    case l of
        Right l -> if p == VerifyAssumptions then return $ sameTypes pos m ann l else makeUnionIfNotSame pos (Right ann) (getAnnotationState lhs) lhs
        Left err -> return $ Left err
consistentTypesPass p (DeclN (ImplOpenFunction lhs args (Just ret) exprs _ pos)) = consistentTypesPass p $ FunctionDef args (Just ret) exprs pos
consistentTypesPass p (DeclN (ImplOpenFunction lhs args Nothing exprs implft pos)) = do
    a <- getAnnotationState lhs
    mp <- getTypeMap
    case a of
        Left err -> return $ Left err
        Right fun@(OpenFunctionAnnotation anns ret' ft impls) -> do
            let defs = Set.unions $ map (collectGenenrics mp . snd) args
            let (specificationRules, rels) = getPartialNoUnderScoreSpecificationRules pos defs Map.empty mp fun (FunctionAnnotation (map snd args) (AnnotationLiteral "_"))
            case substituteVariables pos defs rels specificationRules mp ret' of
                Left err -> return . Left $ "Could not infer the return type: " ++ err ++ "\n" ++ showPos pos
                Right inferredRetType ->
                    case specify pos defs Map.empty mp fun (makeFunAnnotation args inferredRetType) of
                        Left err -> return $ Left err
                        Right ann -> consistentTypesPass p $ FunctionDef args (Just inferredRetType) exprs pos
        Right a -> return . Left $ "Cannot extend function " ++ show a ++ "\n" ++ showPos pos
consistentTypesPass p (DeclN (OpenFunctionDecl lhs ann pos)) =  do
    m <- getTypeMap
    l <- getAnnotationState lhs
    case l of
        Right l -> if p == VerifyAssumptions then return $ sameTypes pos m ann l else makeUnionIfNotSame pos (Right ann) (getAnnotationState lhs) lhs
        Left err -> return $ Left err
consistentTypesPass p (IfExpr cond t e pos) = do
    m <- getTypeMap
    c <- consistentTypesPass p cond
    case c >>= \x -> sameTypes pos m x (AnnotationLiteral "Bool") of
        Right _ -> (\a b -> mergedTypeConcrete pos m <$> a <*> b) <$> consistentTypesPass p t <*> consistentTypesPass p e
        Left err -> return $ Left err
consistentTypesPass p (CreateNewType lhs@(LhsIdentifer id _) args pos) = do
    mp <- getTypeMap
    argsn <- sequence <$> mapM (consistentTypesPass p) args
    case argsn of
        Right as -> return $ case Map.lookup lhs mp of
            Just (NewTypeAnnotation id anns _) -> 
                if length anns == length args then NewTypeInstanceAnnotation id <$> argsn
                else Left $ "Can't match arguments " ++ show as ++ " with " ++ show anns ++ "\n" ++ showPos pos
            Just a -> Left $ show a ++ " is not an instantiable type" ++ showPos pos
            Nothing -> Left $ noTypeFound id pos
        Left err -> return $ Left err
consistentTypesPass p (DeclN (Expr n)) = consistentTypesPass p n
consistentTypesPass p (IfStmnt (RemoveFromUnionNode lhs ann _) ts es pos) = do
    (_, (_, mp)) <- get
    pushScope
    typLhs <- getAnnotationState lhs
    case typLhs of
        Right t@TypeUnion{} -> res t
        Right t@NewTypeInstanceAnnotation{} -> res t
        _ -> return . Left $ expectedUnion pos lhs typLhs
    where res t = do
            eitherAnn <- excludeFromUnion pos ann t
            case eitherAnn of
                Left err -> return $ Left err
                Right ann' -> do
                    insertAnnotation lhs $ Finalizeable False ann'
                    mapM_ getAssumptionType ts
                    t <- sequence <$> mapM (consistentTypesPass p) ts
                    popScope
                    pushScope
                    insertAnnotation lhs (Finalizeable False ann)
                    mapM_ getAssumptionType es
                    e <- sequence <$> mapM (consistentTypesPass p) es
                    popScope
                    let res = case (t, e) of
                            (Right b, Right c) -> Right $ AnnotationLiteral "_"
                            (Left a, _) -> Left a
                            (_, Left a) -> Left a
                    return res
consistentTypesPass p (IfStmnt (CastNode lhs ann _) ts es pos) = do
    (_, (_, mp)) <- get
    pushScope
    insertAnnotation lhs (Finalizeable False ann)
    mapM_ getAssumptionType ts
    t <- sequence <$> mapM (consistentTypesPass p) ts
    popScope
    pushScope
    typLhs <- getAnnotationState lhs
    case typLhs of
        Right ts@TypeUnion{} -> do
            eitherAnn <- excludeFromUnion pos ann ts
            case eitherAnn of
                Right ann -> insertAnnotation lhs $ Finalizeable False ann
                Left err -> return ann
        _ -> return ann
    mapM_ getAssumptionType es
    e <- sequence <$> mapM (consistentTypesPass p) es
    popScope
    let res = case (t, e) of
            (Right b, Right c) -> Right $ AnnotationLiteral "_"
            (Left a, _) -> Left a
            (_, Left a) -> Left a
    return res
consistentTypesPass p (IfStmnt cond ts es pos) = do
    (_, (_, mp)) <- get
    c <- consistentTypesPass p cond
    case sameTypes pos mp (AnnotationLiteral "Bool") <$> c of
        Right _ -> do
            c <- consistentTypesPass p cond
            pushScope
            mapM_ getAssumptionType ts
            t <- sequence <$> mapM (consistentTypesPass p) ts
            popScope
            pushScope
            mapM_ getAssumptionType es
            e <- sequence <$> mapM (consistentTypesPass p) es
            popScope
            let res = case (c, t, e) of
                    (Right a, Right b, Right c) -> Right $ AnnotationLiteral "_"
                    (Left a, _, _) -> Left a
                    (_, Left a, _) -> Left a
                    (_, _, Left a) -> Left a
            return res
        Left err -> return $ Left err
consistentTypesPass p (StructN (Struct ns _)) = (\case
    Right a -> return . Right $ StructAnnotation a
    Left err -> return $ Left err) . sequence =<< mapM (consistentTypesPass p) ns
consistentTypesPass pass (Access st p pos) = do
    mp <- getTypeMap
    f mp =<< getTypeStateFrom (consistentTypesPass pass st) pos where 

    f :: UserDefinedTypes -> Either String Annotation -> AnnotationState (Annotations (Finalizeable Annotation)) (Either String Annotation)
    f mp = \case
            Right g@(GenericAnnotation _ cns) -> return $ genericHas pos g p cns
            Right g@(RigidAnnotation _ cns) -> return $ genericHas pos g p cns
            Right (TypeUnion st) -> ((\x -> head <$> mapM (sameTypes pos mp (head x)) x) =<<) <$> x where 
                x = sequence <$> mapM (\x -> f mp =<< getTypeState x pos) stl
                stl = Set.toList st
            Right (NewTypeInstanceAnnotation id anns) -> 
                accessNewType anns
                (\(NewTypeAnnotation _ _ ps) -> return $ toEither ("Could not find " ++ show p ++ " in " ++ show ps ++ "\n" ++ showPos pos) (Map.lookup p ps)) 
                (LhsIdentifer id pos)
            Right (StructAnnotation ps) -> return $ toEither ("Could not find " ++ show p ++ " in " ++ show ps ++ "\n" ++ showPos pos) (Map.lookup p ps)
            Right a -> return . Left $ "Cannot get " ++ show p ++ " from type " ++ show a ++ "\n" ++ showPos pos
            Left err -> return $ Left err
consistentTypesPass p (FunctionDef args ret body pos) = 
    case ret of
        Just ret -> do
            scope <- get
            finalizeAnnotationState
            (a, ((i, ans), mp)) <- get
            mp <- getTypeMap
            let program = Program body
            let ans' = (a, ((i, assumeProgramMapping program i (Annotations (Map.fromList $ (LhsIdentifer "return" pos, Finalizeable True $ rigidizeTypeVariables mp ret):map (second (Finalizeable True . rigidizeTypeVariables mp)) args) (Just ans)) mp), mp))
            put ans'
            xs <- sequence <$> mapM (consistentTypesPass p) body
            s <- getAnnotationState (LhsIdentifer "return" pos)
            put scope
            case s of
                Right ret' -> case xs of
                    Right _ -> return (sameTypes pos mp (makeFunAnnotation args $ unrigidizeTypeVariables mp ret) (makeFunAnnotation args $ unrigidizeTypeVariables mp ret'))
                    Left err -> return . Left $ err
                Left err -> return $ Left err
        Nothing -> do
            scope <- get
            finalizeAnnotationState
            (a, ((i, old_ans), mp)) <- get
            let program = Program body
            let ans = (a, ((i, assumeProgramMapping program i (Annotations (Map.fromList $ (LhsIdentifer "return" pos, Finalizeable False $ AnnotationLiteral "_"):map (second (Finalizeable True . rigidizeTypeVariables mp)) args) (Just old_ans)) mp), mp))
            put ans
            xs <- sequence <$> mapM (consistentTypesPass p) body
            (_, ((i, new_ans), _)) <- get
            case xs of
                Right _ ->
                    (\case
                        Right ret -> case getAnnotation (LhsIdentifer "return" pos) new_ans of
                            Right (Finalizeable _ ret') -> do
                                typ <- consistentTypesPass p ret
                                put scope
                                return $ Right $ makeFunAnnotation args $ unrigidizeTypeVariables mp ret'
                            Left err -> return $ Left err
                        Left err -> return $ Left err) =<< firstInferrableReturn pos body
                Left err -> return $ Left err
consistentTypesPass p (Return n pos) = consistentTypesPass p n >>= \x -> makeUnionIfNotSame pos x (getAnnotationState lhs) lhs
    where lhs = LhsIdentifer "return" pos
consistentTypesPass p (Call e args pos) =  (\case 
                    Right fann@(FunctionAnnotation fargs ret) -> do
                        mp <- getTypeMap
                        anns <- sequence <$> mapM (consistentTypesPass p) args
                        case anns of
                            Right anns -> let 
                                (spec, rels) = getPartialNoUnderScoreSpecificationRules pos defs Map.empty mp fann (FunctionAnnotation anns (AnnotationLiteral "_")) 
                                defs = Set.unions $ map (collectGenenrics mp) anns in
                                case substituteVariables pos defs rels spec mp ret of
                                    Right ret' -> case specify pos defs Map.empty mp fann (FunctionAnnotation anns ret') of
                                        Right r -> return $ Right ret'
                                        Left err -> return $ Left err
                                    Left err -> return $ Left err
                            Left err -> return $ Left err                    
                    Right opf@(OpenFunctionAnnotation oanns oret ft impls) -> do
                        mp <- getTypeMap
                        anns <- sequence <$> mapM (consistentTypesPass p) args
                        case anns of
                            Right anns -> let 
                                defs = Set.unions $ map (collectGenenrics mp) anns
                                (spec, rel) = getPartialNoUnderScoreSpecificationRules pos defs Map.empty mp (FunctionAnnotation oanns oret) (FunctionAnnotation anns (AnnotationLiteral "_")) in
                                case substituteVariables pos defs rel spec mp oret of
                                    Right ret' -> case getSpecificationRules pos defs Map.empty mp (FunctionAnnotation oanns oret) (FunctionAnnotation anns ret') of
                                        Right base -> case Map.lookup ft base of
                                            Just a -> maybe 
                                                    (return . Left $ "Could find instance " ++ show opf ++ " for " ++ show a ++ "\n" ++ showPos pos) 
                                                    (const . return $ Right ret')
                                                    (find (\b -> specifyTypesBool pos defs base mp b a) impls)
                                            Nothing -> return . Left $ "The argument does not even once occur in the whole method\n" ++ showPos pos
                                        Left err -> return $ Left err
                                    Left err -> return $ Left err
                            Left err -> return $ Left err       
                    Right ann -> return . Left $ "Can't call a value of type " ++ show ann ++ "\n" ++ showPos pos
                    Left err -> return $ Left err) =<< getTypeStateFrom (getAssumptionType e) pos
consistentTypesPass p (Identifier x pos) = getAnnotationState (LhsIdentifer x pos)
consistentTypesPass p (Lit (LitInt _ _)) = return . Right $ AnnotationLiteral "Int"
consistentTypesPass p (Lit (LitBool _ _)) = return . Right $ AnnotationLiteral "Bool"
consistentTypesPass p (Lit (LitString _ _)) = return . Right $ AnnotationLiteral "String"
consistentTypesPass p a = error $ show a

consistentTypes n = consistentTypesPass RefineAssumtpions n >>= \case
    Right _ -> consistentTypesPass VerifyAssumptions n
    Left err -> return $ Left err

onlyTypeDecls :: Node -> Bool
onlyTypeDecls (DeclN StructDef{}) = True
onlyTypeDecls (DeclN NewTypeDecl{}) = True
onlyTypeDecls _ = False

typeNodes :: [Node] -> ([Node], [Node])
typeNodes = partition onlyTypeDecls

typeMap :: [Node] -> Map.Map Lhs (Annotation, P.SourcePos)
typeMap xs = Map.fromList (map makeTup xs) where
    makeTup (DeclN (StructDef lhs rhs pos)) = (lhs, (rhs, pos))
    makeTup (DeclN (NewTypeDecl lhs rhs pos)) = (lhs, (rhs, pos))

allExists :: Map.Map Lhs (Annotation, P.SourcePos) -> Either String ()
allExists mp = mapM_ (exists mp) mp where
    exists :: Map.Map Lhs (Annotation, P.SourcePos) -> (Annotation, P.SourcePos) -> Either String ()
    exists mp (NewTypeAnnotation{}, pos) = Right ()
    exists mp (NewTypeInstanceAnnotation id anns1, pos) = case Map.lookup (LhsIdentifer id pos) mp of
        Just (NewTypeAnnotation id anns2 _, pos) -> if length anns1 == length anns2 then Right () else Left $ "Unequal arguments " ++ show anns1 ++ " can't be matched with " ++ show anns2
        Just a -> Left $ "Cannot instantiate " ++ show a ++ "\n" ++ showPos pos
        Nothing -> Left $ noTypeFound id pos
    exists mp (Annotation id, pos) = 
        case Map.lookup (LhsIdentifer id pos) mp of
            Just _ -> Right ()
            Nothing -> Left $ noTypeFound id pos
    exists mp (AnnotationLiteral lit, pos) = Right ()
    exists mp (FunctionAnnotation as ret, pos) = mapM_ (exists mp . (, pos)) as >> exists mp (ret, pos)
    exists mp (TypeUnion s, pos) = mapM_ (exists mp . (, pos)) (Set.toList s)
    exists mp (OpenFunctionAnnotation anns ret ftr _, pos) = mapM_ (exists mp . (, pos)) $ [ftr, ret] ++ anns
    exists mp (StructAnnotation xs, pos) = mapM_ (exists mp . (, pos)) (Map.elems xs)
    exists mp (GenericAnnotation _ cns, pos) = mapM_ (constraintExists mp . (, pos)) cns where 
        constraintExists mp (ConstraintHas _ cn, pos) = constraintExists mp (cn, pos)
        constraintExists mp (AnnotationConstraint ann, pos) = exists mp (ann, pos)

newTypeName :: P.SourcePos -> DefineTypesState Annotation Lhs
newTypeName pos = do
    s <- get
    (a, ((i, b), c)) <- get
    put (a, ((i+1, b), c))
    return $ LhsIdentifer ("auto_generated_type_" ++ show i) pos

defineSingleType :: P.SourcePos -> Annotation -> DefineTypesState Annotation Annotation
defineSingleType pos (FunctionAnnotation anns ret) = FunctionAnnotation <$> mapM (defineSingleType pos) anns <*> defineSingleType pos ret
defineSingleType pos g@GenericAnnotation{} = return g
defineSingleType pos lit@AnnotationLiteral{} = return lit
defineSingleType pos (OpenFunctionAnnotation anns ret ftr impls) = OpenFunctionAnnotation <$> mapM (defineSingleType pos) anns <*> defineSingleType pos ret <*> defineSingleType pos ftr <*> mapM (defineSingleType pos) impls
defineSingleType pos (NewTypeInstanceAnnotation id anns) = NewTypeInstanceAnnotation id <$> mapM (defineSingleType pos) anns
defineSingleType pos (TypeUnion st) = TypeUnion <$> (Set.fromList <$> mapM (defineSingleType pos) (Set.toList st))
defineSingleType pos ann = do
    mp <- getTypeMap
    case find (isRight . fst) $ Map.mapWithKey (\ann2 v -> (sameTypes pos (invertUserDefinedTypes mp) ann ann2, v)) mp of
        Just (Right ann, lhs@(LhsIdentifer id _)) -> modifyAnnotations lhs (Annotation id) $> Annotation id
        Just a -> error $ "Unexpected " ++ show a ++ " from defineSingleType"
        Nothing -> do
            tn <- newTypeName pos
            addToMap tn ann
            modifyAnnotations tn ann
            defineSingleType pos ann
            modifyAnnotations tn (Annotation $ show tn) $> ann
    where 
        addToMap :: Lhs -> Annotation -> DefineTypesState Annotation ()
        addToMap tn ann = do
            (a, ((i, b), mp)) <- get
            let new_mp = Map.insert ann tn mp
            put (a, ((i, b), new_mp))

        modifyAnnotations :: Lhs -> Annotation -> DefineTypesState Annotation ()
        modifyAnnotations tn ann = do
            (a, ((i, anns), mp)) <- get
            new_anns <- f (invertUserDefinedTypes mp) anns
            put (a, ((i, new_anns), mp))
            where 
                f mp (Annotations anns rest) = Annotations <$> sequence (
                    Map.map (\ann2 -> if isRight $ sameTypesImpl ann2 pos mp ann ann2 then return . Annotation $ show tn else defineSingleType pos ann2) anns
                    ) <*> sequence (f mp <$> rest)

defineTypesState :: Annotations Annotation -> DefineTypesState Annotation (Annotations Annotation)
defineTypesState (Annotations anns rest) = Annotations
  <$> sequence (Map.mapWithKey (\(LhsIdentifer _ pos) v -> defineSingleType pos v) anns)
  <*> sequence (defineTypesState <$> rest)

defineAllTypes :: UserDefinedTypes -> Annotations Annotation -> (UserDefinedTypes, Annotations Annotation)
defineAllTypes usts anns = (invertUserDefinedTypes $ snd $ snd st, snd . fst . snd $ st) where 
    st = execState (defineTypesState anns) (AnnotationLiteral "_", ((0, anns), invertUserDefinedTypes usts))

removeFinalization :: Annotations (Finalizeable a) -> Annotations a
removeFinalization (Annotations anns Nothing) = Annotations (Map.map fromFinalizeable anns) Nothing
removeFinalization (Annotations anns rest) = Annotations (Map.map fromFinalizeable anns) (removeFinalization <$> rest)

addFinalization :: Annotations a -> Annotations (Finalizeable a)
addFinalization (Annotations anns Nothing) = Annotations (Map.map (Finalizeable True) anns) Nothing
addFinalization (Annotations anns rest) = Annotations (Map.map (Finalizeable True) anns) (addFinalization <$> rest)

invertUserDefinedTypes :: Ord k => Map.Map a k -> Map.Map k a
invertUserDefinedTypes usts = Map.fromList $ Map.elems $ Map.mapWithKey (curry swap) usts

predefinedTypeNodes :: [Node]
predefinedTypeNodes = map DeclN [
    StructDef (LhsIdentifer "Nil" sourcePos) (StructAnnotation Map.empty) sourcePos,
    NewTypeDecl (LhsIdentifer "Array" sourcePos) (NewTypeAnnotation "Array" [GenericAnnotation "x" []] $ Map.singleton (LhsIdentifer "a" sourcePos) $ GenericAnnotation "x" []) sourcePos
    ]

typeCheckedScope :: [Node] -> Either String ([Node], [Node], (UserDefinedTypes, Annotations Annotation))
typeCheckedScope program = 
    do
        allExists typesPos
        case runState (mapM getAssumptionType earlyReturns) (AnnotationLiteral "_", ((0, assumeProgram (Program $ earlyReturnToElse lifted) 0 types), types)) of
            (res, (a, map@(_, usts))) -> case sequence_ res of
                Left err -> Left err 
                Right () -> res >> Right (metProgram, earlyReturns, (usts, removeFinalization as)) where
                        res = sequence f
                        (_, ((_, as), _)) = s
                        (f, s) = runState (mapM consistentTypes (earlyReturnToElse lifted)) (a, map)
    where 
        earlyReturns = earlyReturnToElse lifted
        lifted = evalState (liftLambda restProgram) (0, [])
        (_metProgram, restProgram) = typeNodes program
        metProgram = _metProgram ++ predefinedTypeNodes
        typesPos = typeMap $ metProgram
        types = Map.map fst typesPos
