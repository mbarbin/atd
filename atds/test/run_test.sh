#!/bin/sh

set -e
CLASSPATH='.:argonaut_2.12-6.2.2.jar:junit-4.8.2.jar'

scalac -classpath $CLASSPATH test.scala
scalac -classpath $CLASSPATH AtdsTest.scala
scaladoc -classpath $CLASSPATH test.scala -d doc 2>&1 |
    grep -q 'model contains [0-9]* documentable templates'
scala  -classpath $CLASSPATH AtdsTest > scala.trace || {
    cat scala.trace
    exit 1
}
