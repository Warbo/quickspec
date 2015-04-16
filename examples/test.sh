#!/bin/sh
for test in *.hs
do
    runhaskell "$test"
done
