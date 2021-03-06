#!/bin/bash

# Name: magma.killhard.sh
# Author: Ladar Levison
#
# Description: Used for killing the magma daemon when it takes too long to shutdown normally.

# Handle self referencing, sourcing etc.
if [[ $0 != $BASH_SOURCE ]]; then
  export CMD=`readlink -f $BASH_SOURCE`
else
  export CMD=`readlink -f $0`
fi

# Cross Platform Base Directory Discovery
pushd `dirname $CMD` > /dev/null
BASE=`pwd -P`
popd > /dev/null

cd $BASE/../../../

MAGMA_DIST=`pwd`

PID=`ps -ef | egrep "$MAGMA_DIST/magmad|$MAGMA_DIST/magmad.check|$MAGMA_DIST/dev/tools/mason/.debug/mason|/home/magma/magmad" | grep -v grep | awk -F' ' '{ print $2}'`
if [ "$PID" = '' ]; then
	echo "no magma instances to kill"
else
	kill -9 $PID
	PID=${PID//
/ }
	if [ $? -eq 0 ]; then
		sleep 1
	fi
	echo "magma process ids $PID killed"
fi
