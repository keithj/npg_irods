#!/bin/bash

set -e -x

export TEST_AUTHOR=1
export TEST_WITH_H5REPACK=1
export WTSI_NPG_iRODS_Test_irodsEnvFile=NULL
export WTSI_NPG_iRODS_Test_IRODS_ENVIRONMENT_FILE=$HOME/.irods/irods_environment.json

. ~/miniconda/etc/profile.d/conda.sh
conda activate travis

echo "irods" | script -q -c "iinit" /dev/null
ienv
ils

which baton-do
baton-do --version

cpanm --local-lib=~/perl5 local::lib && eval $(perl -I ~/perl5/lib/perl5/ -Mlocal::lib)

export PERL5LIB="$PWD:$PERL5LIB"
perl Build.PL
./Build clean
./Build test
