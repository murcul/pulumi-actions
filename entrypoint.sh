#!/bin/bash
# This is an entrypoint for our Docker image that does some minimal bootstrapping before executing.

set -e
set -x

# For Google, we need to authenticate with a service principal for certain authentication operations.
if [ ! -z "$GOOGLE_CREDENTIALS" ]; then
    GCLOUD_KEYFILE="$(mktemp).json"
    echo "$GOOGLE_CREDENTIALS" > $GCLOUD_KEYFILE
    gcloud auth activate-service-account --key-file=$GCLOUD_KEYFILE
    helm init --client-only
fi

# If the PULUMI_CI variable is set, we'll do some extra things to make common tasks easier.
if [ ! -z "$PULUMI_CI" ]; then
    # Capture the PWD before we go and potentially change it.
    ROOT=$(pwd)

    # If the root of the Pulumi project isn't the root of the repo, CD into it.
    if [ ! -z "$PULUMI_ROOT" ]; then
        cd $PULUMI_ROOT
    fi

    # Detect the CI system and configure variables so that we get good Pulumi workflow and GitHub App support.
    if [ ! -z "$GITHUB_WORKFLOW" ]; then
        export PULUMI_CI_SYSTEM="GitHub"
        export PULUMI_CI_BUILD_ID=
        export PULUMI_CI_BUILD_TYPE=
        export PULUMI_CI_BUILD_URL=
        export PULUMI_CI_PULL_REQUEST_SHA="$GITHUB_SHA"

        BRANCH=$(echo $GITHUB_REF | sed "s/refs\/heads\///g")
        if [ -e $ROOT/.pulumi/ci.json ]; then
            CI_STACK_NAME=$(cat $ROOT/.pulumi/ci.json | jq -r ".\"$BRANCH\"")
        fi

        if [ ! -z "$CI_STACK_NAME" ] && [ "$CI_STACK_NAME" != "null" ]; then
            PULUMI_STACK_NAME="$CI_STACK_NAME"
            unset PULUMI_REVIEW_STACKS
        elif [ ! -z "$PULUMI_REVIEW_STACKS" ]; then
            PULUMI_STACK_NAME="$BRANCH-review"
        fi

        if [ "$PULUMI_CI" = "pr" ]; then
            # Not all PR events warrant running a preview. Many of them pertain to changes in assignments and
            # ownership, but we only want to run the preview if the action is "opened", "edited", or "synchronize".
            PR_ACTION=$(jq -r ".action" < $GITHUB_EVENT_PATH)

            # For review stacks, create / destroy dynamically
            if [ ! -z "$PULUMI_REVIEW_STACKS" ]; then
                if [ "$PR_ACTION" = "opened" ] || [ "$PR_ACTION" = "reopened" ]; then
                    pulumi stack init $PULUMI_STACK_NAME
                elif [ "$PR_ACTION" = "closed" ]; then
                    pulumi --non-interactive destroy -s $PULUMI_STACK_NAME
                    pulumi --non-interactive stack rm --yes $PULUMI_STACK_NAME
                fi
            elif [ -z "$PULUMI_STACK_NAME" ]; then
                # Without review stacks, we want to take the ref of the target branch, not the current. This ensures, for
                # instance, that a PR for a topic branch merging into `master` will use the `master` branch as the
                # target for a preview. Note that for push events, we of course want to use the actual branch.
                BRANCH=$(jq -r ".pull_request.base.ref" < $GITHUB_EVENT_PATH)
                BRANCH=$(echo $BRANCH | sed "s/refs\/heads\///g")
            fi

            if [ "$PR_ACTION" != "opened" ] && [ "$PR_ACTION" != "edited" ] && [ "$PR_ACTION" != "synchronize" ] && [ "$PR_ACTION" != "reopened" ]; then
                echo -e "PR event ($PR_ACTION) contains no changes and does not warrant a Pulumi Preview"
                echo -e "Skipping Pulumi action altogether..."
                exit 0
            fi
            export PULUMI_CONFIG_BUILD_TAG=$BRANCH
            export PULUMI_CONFIG_BUILD_SHA=$GITHUB_SHA
        fi
        export PULUMI_CONFIG_BUILD_TAG=$BRANCH
        export PULUMI_CONFIG_BUILD_SHA=$GITHUB_SHA
    fi

    # Respect the branch mappings file for stack selection. Note that this is *not* required, but if the file
    # is missing, the caller of this script will need to pass `-s <stack-name>` to specify the stack explicitly.
    if [ ! -z "$BRANCH" ]; then
        if [ -z "$PULUMI_STACK_NAME" ]; then
            if [ -e $ROOT/.pulumi/ci.json ]; then
                PULUMI_STACK_NAME=$(cat $ROOT/.pulumi/ci.json | jq -r ".\"$BRANCH\"")
            else
                # If there's no stack mapping file, we are on master, and there's a single stack, use it.
                PULUMI_STACK_NAME=$(pulumi stack ls | awk 'FNR == 2 {print $1}' | sed 's/\*//g')
            fi
        fi

        if [ ! -z "$PULUMI_STACK_NAME" ] && [ "$PULUMI_STACK_NAME" != "null" ]; then
            echo -e "Selecting Pulumi Stack ($PULUMI_STACK_NAME)"
            pulumi stack select $PULUMI_STACK_NAME
        else
            echo -e "No stack configured for branch '$BRANCH'"
            echo -e ""
            echo -e "To configure this branch, please"
            echo -e "\t1) Run 'pulumi stack init <stack-name>'"
            echo -e "\t2) Associated the stack with the branch by adding"
            echo -e "\t\t{"
            echo -e "\t\t\t\"$BRANCH\": \"<stack-name>\""
            echo -e "\t\t}"
            echo -e "\tto your .pulumi/ci.json file"
            echo -e ""
            echo -e "For now, exiting cleanly without doing anything..."
            exit 0
        fi
    fi
fi

if [ ! -z "$GOOGLE_CREDENTIALS" ]; then
    echo -e "Found Google Credentials. Setting ...."
    pulumi config set --plaintext gcp:project $PULUMI_CONFIG_GCP_PROJECT
    pulumi config set --plaintext gcp:zone $PULUMI_CONFIG_GCP_ZONE
fi

if [ ! -z "$PULUMI_CONFIG_CLOUDFLARE_KEY" ]; then
    echo -e "Found Cloudflare credentials. Setting ...."
    pulumi config set --plaintext cloudflare:email $PULUMI_CONFIG_CLOUDFLARE_EMAIL
    pulumi config set --plaintext cloudflare:token $PULUMI_CONFIG_CLOUDFLARE_KEY
fi

if [ ! -z "$PULUMI_CONFIG_KUBECONFIG" ]; then
    echo -e "Found kubernetes credentials. Setting ...."
    pulumi config set --plaintext kubernetes:kubeconfig < echo $PULUMI_CONFIG_KUBECONFIG
fi


# Add pulumi config vars
for varname in ${!PULUMI_CONFIG*}
do
    echo setting ${varname/PULUMI_CONFIG_/}=${!varname}
    pulumi config set --plaintext ${varname/PULUMI_CONFIG_/} ${!varname}
done

# Next, lazily install packages if required.
if [ -e package.json ] && [ ! -d node_modules ]; then
    echo -e "Installing NPM packages...."
    npm install
fi

echo -e "Running Pulumi CLI (pulumi --non-interactive $*) ...."
# Now just pass along all arguments to the Pulumi CLI.
OUTPUT=$(sh -c "pulumi --non-interactive $*" 2>&1)
EXIT_CODE=$?

echo "#### :tropical_drink: \`pulumi ${@:2}\`"
echo "$OUTPUT"

# If the GitHub action stems from a Pull Request event, we may optionally leave a comment if the
# COMMENT_ON_PR is set.
COMMENTS_URL=$(cat $GITHUB_EVENT_PATH | jq -r .pull_request.comments_url)
if [ ! -z $COMMENTS_URL ] && [ ! -z $COMMENT_ON_PR ]; then
    if [ -z $GITHUB_TOKEN ]; then
        echo "ERROR: COMMENT_ON_PR was set, but GITHUB_TOKEN is not set."
    else
        COMMENT="#### :tropical_drink: \`pulumi ${@:2}\`
\`\`\`
$OUTPUT
\`\`\`"
        PAYLOAD=$(echo '{}' | jq --arg body "$COMMENT" '.body = $body')
        echo "Commenting on PR $COMMENTS_URL"
        curl -s -S -H "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/json" --data "$PAYLOAD" "$COMMENTS_URL"
    fi
fi

exit $EXIT_CODE
