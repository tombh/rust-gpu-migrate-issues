#!/usr/bin/env bash

# Dependencies:
#   * `gh` Github CLI: https://cli.github.com
#   * `jq` JSON parser: https://github.com/jqlang/jq

# USAGE:
#   1. Create a dedicated `rust-gpu-bot` user.
#   2. Update the following variables:
# The repo to which issues should be copied.
RUST_GPU_REPO=tombh/rust-gpu-migrate-issues
# We could use "@" to ping the original author of the issue.
AUTHOR_PREFIX=""
# The repo where the original issues are (ie Embark) and so where an issue comment should be made notifying of the new
# tracking issue.
REPO_TO_NOTIFY=tombh/rust-gpu-migrate-issues

START_FROM_ISSUE_NUMBER=1150 # Useful if the migration crashes half way though.
EMBARK_REPO=embarkstudios/rust-gpu
CACHED_ISSUES_FILE=issues.json

function main {
	has_reached_first_issue=false

	jq -c '.[]' <"$CACHED_ISSUES_FILE" |
		while read -r issue; do
			new_issue_number=$(echo "$issue" | jq -r .number)
			if [ "$new_issue_number" == "$START_FROM_ISSUE_NUMBER" ]; then
				has_reached_first_issue=true
			fi
			if [ "$has_reached_first_issue" == "false" ]; then
				continue
			fi

			old_issue_number=$(echo "$issue" | jq -r .number)
			author=$(echo "$issue" | jq -r .author.login)
			body=$(echo "$issue" | jq -r .body)
			comments=$(echo "$issue" | jq -r .comments)
			createdAt=$(echo "$issue" | jq -r .createdAt)
			labels=$(echo "$issue" | jq -r .labels)
			reactionGroups=$(echo "$issue" | jq -r .reactionGroups)
			title=$(echo "$issue" | jq -r .title)
			url=$(echo "$issue" | jq -r .url)

			echo "Creating issue from $url ..."
			new_issue_number=$(create_rust_gpu_issue "$author" "$title" "$body" "$labels" "$reactionGroups" "$createdAt" "$url")
			create_comments "$new_issue_number" "$comments"
			create_comment_in_old_issue "$old_issue_number" "$new_issue_number"

			echo
		done

}

function github_api {
	# Rate limit is 5000 requests per hour. So try not to go over that.
	# If you're sure that there's not going to be any problems then I doubt all the old Embark issues and comments
	# will generate this many API requests. So it'd be fine to set this to 0.
	sleep 1

	gh "$@"
}

function get_embark_issues {
	github_api \
		issue list \
		--repo "$EMBARK_REPO" \
		--state open \
		--limit 100 \
		--json author,body,comments,createdAt,number,labels,reactionGroups,title,url |
		jq >"$CACHED_ISSUES_FILE"
}

function create_rust_gpu_issue {
	author=$1
	title=$2
	old_body=$3
	old_labels=$4
	reactionGroups=$5
	createdAt=$6
	url=$7

	new_body=$(generate_issue_body "$old_body" "$author" "$createdAt" "$reactionGroups" "$url" "$old_labels")

	args=(
		issue
		create
		--repo "$RUST_GPU_REPO"
		--title "[Migrated] $title"
		--body "$new_body"
	)

	new_labels=$(generate_labels "$old_labels")
	IFS=, read -ra labels <<<"$new_labels"
	for label in "${labels[@]}"; do
		args+=(--label "$label")
	done

	response=$(github_api "${args[@]}")
	new_issue_number=$(echo "$response" | awk -F/ '{print $NF}')

	echo "$new_issue_number"
}

function create_comments {
	new_issue_number=$1
	comments=$2

	echo "$comments" | jq -c '.[]' |
		while read -r comment; do
			author=$(echo "$comment" | jq -r .author.login)
			authorAssociation=$(echo "$comment" | jq -r .authorAssociation)
			old_body=$(echo "$comment" | jq -r .body)
			createdAt=$(echo "$comment" | jq -r .createdAt)
			reactionGroups=$(echo "$comment" | jq -r .reactionGroups)

			authorAssociation=$([[ $authorAssociation != "NONE" ]] && echo "($authorAssociation)")
			reactionsText=$(generate_reactions_text "$reactionGroups")

			read -r -d '' new_body <<-EOM
				_Comment from $author $authorAssociation on ${createdAt}_ ${reactionsText}

				---

				$old_body
			EOM

			echo -n "Creating comment: "
			github_api \
				issue comment "$new_issue_number" \
				--repo "$RUST_GPU_REPO" \
				--body "$new_body"
		done
}

function create_comment_in_old_issue {
	old_issue_number=$1
	new_issue_number=$2

	read -r -d '' comment <<-EOM
		This issue is now being tracked at: https://github.com/$RUST_GPU_REPO/issues/$new_issue_number
	EOM

	echo -n "Creating comment in old repo: "
	github_api \
		issue comment "$new_issue_number" \
		--repo "$REPO_TO_NOTIFY" \
		--body "$comment"
}

function generate_issue_body {
	old_body=$1
	author=$2
	createdAt=$3
	reactionGroups=$4
	url=$5
	old_labels=$6

	reactionsText=$(generate_reactions_text "$reactionGroups")
	all_labels=$(echo "$old_labels" | jq -r 'map(.name) | join(",")')
	all_labels=$([[ $all_labels != "" ]] && echo "_Old labels: ${all_labels}"_)

	read -r -d '' new_body <<-EOM
		_Issue automatically imported from old repo: ${url}_
		$all_labels
		_Originally creatd by $AUTHOR_PREFIX$author on ${createdAt}_ ${reactionsText}

		---

		$old_body
	EOM

	echo "$new_body"
}

function generate_reactions_text {
	reactionGroups=$1

	echo "$reactionGroups" | jq -c '.[]' |
		while read -r reaction; do
			kind=$(echo "$reaction" | jq -r .content)
			case "$kind" in
			THUMBS_UP)
				emoji=👍
				;;
			THUMBS_DOWN)
				emoji=👎
				;;
			LAUGH)
				emoji=😆
				;;
			CONFUSED)
				emoji=😕
				;;
			ROCKET)
				emoji=🚀
				;;
			HOORAY)
				emoji=🎉
				;;
			HEART)
				emoji=❤️
				;;
			EYES)
				emoji=👀
				;;
			*)
				emoji=❔
				;;
			esac

			count=$(echo "$reaction" | jq -r .users.totalCount)

			echo -n "$emoji: $count "
		done
}

function generate_labels {
	old_labels=$1

	echo -n "migrated,"

	echo "$old_labels" | jq -c '.[]' |
		while read -r object; do
			label=$(echo "$object" | jq -r .name)
			case "$label" in
			"t: bug")
				new_label="bug"
				;;
			"t: good first issue")
				new_label="good first issue"
				;;
			"t: help wanted")
				new_label="help wanted"
				;;
			"t: question")
				new_label="question"
				;;
			"invalid")
				new_label="invalid"
				;;
			"dependencies")
				new_label="dependencies"
				;;
			"s: wontfix")
				new_label="wontfix"
				;;
			"t: enhancement")
				new_label="enhancement"
				;;
			"t: duplicate")
				new_label="duplicate"
				;;
			"a: documentation")
				new_label="documentation"
				;;
			*)
				new_label=""
				;;
			esac

			echo -n "$new_label,"
		done
}

main
