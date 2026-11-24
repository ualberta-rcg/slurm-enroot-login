# ComputeCanada / Alliance CVMFS software stack (parity with the host's
# ww-overlay zz-cvmfs.sh). The entire module system (Lmod, module trees,
# modulerc) lives on CVMFS; nothing is installed in the image. Sourcing
# this defines Lmod's `module` command and repoints MODULEPATH/MODULERCFILE
# at /cvmfs, overriding the fallback environment-modules shipped in the
# image. Guarded so the image stays portable on clusters without this
# repository mounted.
if [ -r /cvmfs/soft.computecanada.ca/config/profile/bash.sh ]; then
    . /cvmfs/soft.computecanada.ca/config/profile/bash.sh
fi
