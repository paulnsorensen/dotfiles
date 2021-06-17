ad() {
  if [ -z "$@" ]
  then
    echo "gimmie a message pls"
  else
    git add .
    git commit -m "$@"
    arc diff --verbatim
  fi
}
