set -e
cd lib
set +e
out="$("$GO" vet . 2>&1)"
rc=$?
set -e
printf '%s\n' "$out" | grep -v '^#' | sed -E 's/^vet: //'
echo "vet rc=$rc"
