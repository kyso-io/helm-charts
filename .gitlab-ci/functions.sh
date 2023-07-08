#!/bin/sh
print_file()
{
  if [ -f "$1" ]; then
    echo "--*-- BEG FILE: '$1' --*--"
    cat "$1"
    echo "--*-- END FILE: '$1' --*--"
  else
    echo "ERROR: file '$1' not found"
  fi
}

git_push_setup()
{
  # Make sure we are on the root of the project dir
  cd "$CI_PROJECT_DIR" || exit 1
  # Define user name and credentials
  if [ "$CI_PROTECTED_GIT_TOKEN" ]; then
    export GITLAB_USER_LOGIN="$CI_PROTECTED_GIT_USER"
    export GITLAB_USER_TOKEN="$CI_PROTECTED_GIT_TOKEN"
  else
    export GITLAB_USER_LOGIN="$CI_GIT_USER"
    export GITLAB_USER_TOKEN="$CI_GIT_TOKEN"
  fi
  # Compute repository URL with the right credentials
  URL="https://$GITLAB_USER_LOGIN:$GITLAB_USER_TOKEN@${CI_REPOSITORY_URL#*@}"
  # Update remote origin to use the new credentials
  git remote set-url origin "$URL"
}

store_changed_files_for_pipeline()
{
  output_file="$1"
  # Function to get a list of changed files on a push or a merge request
  # Exit if we don't have a commit
  [ "$CI_COMMIT_SHA" ] || return 0
  # Compute the diff base (variables change if we are on a MR or a PUSH)
  if [ "$CI_MERGE_REQUEST_DIFF_BASE_SHA" ]; then
    DIFF_BASE_SHA="$CI_MERGE_REQUEST_DIFF_BASE_SHA"
  elif [ "$CI_COMMIT_BEFORE_SHA" ]; then
    DIFF_BASE_SHA="$CI_COMMIT_BEFORE_SHA"
  fi
  if [ "$DIFF_BASE_SHA" != "0000000000000000000000000000000000000000" ] && [ "$DIFF_BASE_SHA" ]; then
    # Just in case, fetch commits between the current one and the base
    git fetch --depth 1 origin "$DIFF_BASE_SHA"
    # Use git to get the list of changed files
    git diff-tree --no-commit-id --name-only -r "$DIFF_BASE_SHA" "$CI_COMMIT_SHA" >"$output_file"
  else
    # Special case, i.e. initial commit on a branch
    git diff-tree --no-commit-id --name-only -r "$CI_COMMIT_SHA" >"$output_file"
  fi
}

gen_package_json_files()
{
  package_json_tmpl="${GITLAB_CI_DIR}/package.json.tmpl"
  ws_package_json_tmpl="${GITLAB_CI_DIR}/ws-package.json.tmpl"
  ws_plugin="${GITLAB_CI_DIR}/log-versions.js"
  # Get the list of chart paths in YAML format
  if [ ! -f "$CHART_PATHS_YAML" ]; then
    echo "chart_paths:" >"$CHART_PATHS_YAML" 
    find "$CI_PROJECT_DIR" -name 'Chart.yaml' -type f | sort |
      sed -e "s%^$CI_PROJECT_DIR/\(.*\)/Chart.yaml%- \1%" >>"$CHART_PATHS_YAML"
  fi
  # Create main package.json file using the chart_paths as input
  tmpl -f "$CHART_PATHS_YAML" "$package_json_tmpl" | jq . >"$PACKAGE_JSON"
  print_file "$PACKAGE_JSON"
  # Create the package.json for each workspace (each chart is one workspace)
  jq -r '.workspaces[]' "$PACKAGE_JSON" | while read -r ws_path; do
    [ "$ws_path" ] || continue
    ws_name="$(basename "$ws_path")"
    ws_package_json="$CI_PROJECT_DIR/$ws_path/package.json"
    # Generate the package.json passing the 'branch', the 'msr_local_plugin',
    # the 'pkg_name', the 'pkg_path' and the template
    tmpl -v "branch=${CI_COMMIT_BRANCH}" \
      -v "ws_name=$ws_name" \
      -v "ws_path=$ws_path" \
      -v "ws_plugin=$ws_plugin" \
      "$ws_package_json_tmpl" | jq . >"$ws_package_json"
    print_file "$ws_package_json"
  done
}

gen_updated_charts_list()
{
  : >"$CHARTS_TO_REVIEW"
  msr_dry_run_log_path="/tmp/msr-dry-run.log"
  tmp_updated_charts="/tmp/updated_charts.txt"
  tmp_changed_files="/tmp/changed_files.txt"
  : >"$tmp_updated_charts"
  # Get the list of updated charts from multi-semantic-release
  multi-semantic-release --dry-run >"$msr_dry_run_log_path" 2>/dev/null
  print_file "$msr_dry_run_log_path"
  updated_scmd='s%^\[[^]]\+\] \[\([^]]\+\)\] .* NEXT_VERSION=\([^ ]\+\).*$%\1%p'
  sed -ne "$updated_scmd" "$msr_dry_run_log_path" >>"$tmp_updated_charts"
  print_file "$tmp_updated_charts"
  rm -f "$msr_dry_run_log_path"
  # Get the list of updated charts from git
  store_changed_files_for_pipeline "$tmp_changed_files"
  print_file "$tmp_changed_files"
  jq -r '.workspaces[]' "$PACKAGE_JSON" | while read -r chart_path; do
    [ "$chart_path" ] || continue
    if grep -q "^$chart_path" "$tmp_changed_files" 2>/dev/null; then
      echo "$chart_path" >>"$tmp_updated_charts"
	fi
  done
  print_file "$tmp_updated_charts"
  rm -f "$tmp_changed_files"
  # Get the list of updated charts from git or from msr
  jq -r '.workspaces[]' "$PACKAGE_JSON" | while read -r chart_path; do
    [ "$chart_path" ] || continue
    if grep -q "^$chart_path$" "$tmp_updated_charts" 2>/dev/null; then
      echo "$chart_path" >>"$CHARTS_TO_REVIEW"
	fi
  done
  rm -f "$tmp_updated_charts"
  print_file "$CHARTS_TO_REVIEW"
}

lint_charts_from_updated_charts_list()
{
  ret=0
  while read -r chart_path; do
    echo "Linting chart '$chart_path'"
	helm lint "$chart_path" || ret="$?"
  done <"$CHARTS_TO_REVIEW"
  return $ret
}

publish_chart_from_release_tag()
{
  # releases go to the stable channel
  channel="stable"
  chart_name="${CI_COMMIT_REF_NAME%%@*}"
  chart_vers="${CI_COMMIT_REF_NAME#*@}"
  helm package "${chart_name}" --version "${chart_vers}"
  project_api="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}"
  post_url="${project_api}/packages/helm/api/${channel}/charts"
  echo "Posting chart '${chart_name}-${chart_vers}.tgz' to '${post_url}'"
  curl --request POST \
       --user "gitlab-ci-token:$CI_JOB_TOKEN" \
       --form "chart=@${chart_name}-${chart_vers}.tgz" \
       "$post_url"
}
