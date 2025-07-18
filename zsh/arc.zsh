ad() {
  if [[ -z "$*" ]]; then
    echo "gimmie a message pls" >&2
    return 1
  fi
  
  git add . && git commit -m "$*" && arc diff --verbatim
}
