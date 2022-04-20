{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

module Week05.Homework2 where

import           Control.Monad          hiding (fmap)
import qualified Data.Map               as Map
import           Data.Text              (Text)
import           Data.Void              (Void)
import           Plutus.Contract        as Contract
import           Plutus.Trace.Emulator  as Emulator
import qualified PlutusTx
import           PlutusTx.Prelude       hiding (Semigroup(..), unless)
import           Ledger                 hiding (mint, singleton)
import           Ledger.Constraints     as Constraints
import qualified Ledger.Typed.Scripts   as Scripts
import           Ledger.Value           as Value
import           Prelude                (IO, Semigroup (..), Show (..), String, undefined)
import           Text.Printf            (printf)
import           Wallet.Emulator.Wallet

{-# INLINABLE tn #-}
tn :: TokenName
tn = Token emptyByteString 

{-# INLINABLE mkPolicy #-}
-- Minting policy for an NFT, where the minting transaction must consume the given UTxO as input
-- and where the TokenName will be the empty ByteString.
mkPolicy :: TxOutRef -> () -> ScriptContext -> Bool
mkPolicy oref () ctx = traceIfFalse "Specified UTxO has not been consumed" hasUTxo 
                       traceIfFalse "Does not has the correct minting value for an NFT" mintValue 

  where 
    info :: TxInfo 
    info = scriptContextTxInfo ctx 

    hasUTxO :: Bool 
    hasUTxO = any (\x -> txInInfoOutRef x == oref ) txInfoInputs info 

    mintValue :: Bool 
    mintValue = case txInfoMint info of 
      [(cs',tn',amt')] -> cs' == ownCurrencySymbol ctx && tn' == tn && amt == 1 
      _                -> False 

policy :: TxOutRef -> Scripts.MintingPolicy
policy oref = mkMintingPolicyScript $ 
    $$(PlutusTx.compile [|| Scripts.wrapMintingPolicy . mkPolicy ||]) 
    `PlutusTx.applyCode`
    PlutusTx.liftCode oref 

curSymbol :: TxOutRef -> CurrencySymbol
curSymbol = scriptCurrencySymbol . policy 

type NFTSchema = Endpoint "mint" Address

mint :: Address -> Contract w NFTSchema Text ()
mint addr = do 
    utxos <- utxosAt addr 
    case Map.keys utxos of 
      []       -> logError @String "No UTxOs at this address"
      oref : _ -> do
        let val = singleton (curSymbol oref) tn 1 
            lookups = Constraints.mintingPolicy (policy oref) <> Constraints.unspentOutputs utxos
            tx = Constraints.mustMintValue val <> Constraints.mustSpendPubKeyOutput oref
        ledgerTx <- submitTxConstraintsWith @Void lookups tx 
        void $ awaitTxConfirmed getCardanoTxId ledgerTx
        Contact.logInfo @String $ printf "Minted %s" show $ flattenValue val 

endpoints :: Contract () NFTSchema Text ()
endpoints = mint' >> endpoints
  where
    mint' = awaitPromise $ endpoint @"mint" mint

test :: IO ()
test = runEmulatorTraceIO $ do
    let w1 = knownWallet 1
        w2 = knownWallet 2
    h1 <- activateContractWallet w1 endpoints
    h2 <- activateContractWallet w2 endpoints
    callEndpoint @"mint" h1 $ mockWalletAddress w1
    callEndpoint @"mint" h2 $ mockWalletAddress w2
    void $ Emulator.waitNSlots 1