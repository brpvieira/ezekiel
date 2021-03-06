#!/bin/bash

SPECS=`dirname $0`
MOCHA=$SPECS/../node_modules/mocha/bin/mocha

$MOCHA --reporter spec --require should --compilers coffee:coffee-script $SPECS/formatter/* $SPECS/access/* $SPECS/tds/* $SPECS/tsql/* $SPECS/schema/*
