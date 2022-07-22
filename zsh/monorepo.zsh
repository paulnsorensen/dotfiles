# Helper functions and env var for making development in monorepos easier
# (I use this in my zshrc.local for our build systems at work)


if [ -f $HOME/.devdir ]; then
  export DEVDIR=`cat $HOME/.devdir`
  echo "dev dir is set to $DEVDIR"
fi

function dd() {
  local cwd=`pwd`
  echo $cwd
  cd $1 && export DEVDIR=`pwd` && cd $cwd
  echo "$DEVDIR" > $HOME/.devdir
  echo "Set dev dir to $DEVDIR"
}

alias cddd="cd $DEVDIR" 
