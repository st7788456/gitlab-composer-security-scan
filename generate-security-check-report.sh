#!/bin/bash

getProjects () {
	curl --header "PRIVATE-TOKEN: $token" "https://$hostDomain/api/v4/groups/$groupIdOfIS/projects?simple=1&archived=0&per_page=$perPage&order_by=id&page=$page"
}

getFile () {
	# return reponse and http code
	curl --header "PRIVATE-TOKEN: $token" --silent --write-out "HTTPSTATUS:%{http_code}" "https://$hostDomain/api/v4/projects/$1/repository/files/$2/raw?ref=master"
}

getHttpBody () {
	echo $1 | sed -E 's/HTTPSTATUS\:[0-9]{3}$//'
}

getHttpStatus () {
	echo $1 | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/'
}

getRepositoryTree () {
	# currently, we only fetch 100 items of the tree of certain path
	# it's enough for our project
	curl --header "PRIVATE-TOKEN: $token" "https://$hostDomain/api/v4/projects/$1/repository/tree?ref=master&path=$2&per_page=$perPage"
}

analyzeComposerLockFile () {
	if [ ! -d "report/$2" ]; then
		mkdir "report/$2"
	fi

	echo "$1" > "report/$2/composer.lock"
	symfony security:check --format=json --dir="report/$2" > "report/$2/composer-security-report.json"
}

analyzePackageLockFile () {
	if [ ! -d "report/$3" ]; then
		mkdir "report/$3"
	fi

	echo "$1" > "report/$3/package-lock.json"
	echo "$2" > "report/$3/package.json"

	cd "report/$3"
	npm audit --json > "npm-security-report.json"
	cd ../..
}

# load the configuration
. env.conf
# gitlab access token
token="$ACCESS_TOKEN"
# git lab host
hostDomain="$GITLAB_HOST"
# group id
groupIdOfIS="$GROUP_ID"

# intial page valude
page=1
# items per page for pagination
perPage=100
# color for print messages
GREEN="\033[0;32m"

# make the directory for storing composer.lock and report files
if [ ! -d report ]; then
	mkdir report
fi

while true
do
	projects=$(getProjects)

	if [ "[]" == "$projects" ]; then
		echo "There is no more project."
		break;
	fi

	for key in $(jq 'keys | .[]' <<<  "$projects"); do
		project=$(jq -r ".[$key]" <<<  "$projects")
		projectName=$(jq -r '.name' <<< "$project")
		projectId=$(jq -r '.id' <<< "$project")

		echo "Retrieve data of $projectName #$projectId"
		tree=$(getRepositoryTree "$projectId" "")
		nextLayerPaths=()
		composerFound=false
		packageFound=false
		# search composer.lock at the root of the project
		for index in $(jq 'keys | .[]' <<<  "$tree"); do
			obj=$(jq -r ".[$index]" <<<  "$tree")
			type=$(jq -r '.type' <<< "$obj")
			name=$(jq -r '.name' <<< "$obj")
			path=$(jq -r '.path' <<< "$obj")
			# get composer.lock
			if [ "composer.lock" = "$name" ]; then
				response=$(getFile "$projectId" "$path")
				fileContent=$(getHttpBody "$response")
				analyzeComposerLockFile "$fileContent" "$projectName"
				composerFound=true
				echo "composer.lock is found in the root"
			fi
			# get package-lock.json
			if [ "package-lock.json" = "$name" ]; then
				response=$(getFile "$projectId" "$path")
				packageLockContent=$(getHttpBody "$response")
				response=$(getFile "$projectId" "package.json")
				packageJsonContent=$(getHttpBody "$response")
				analyzePackageLockFile "$packageLockContent" "$packageJsonContent" "$projectName"
				packageFound=true
				echo "package-lock.json is found in the root"
			fi
			# some project would put package-lock.json in the frontend folder
			if [ "frontend" = "$name" ] && [ "tree" = "$type" ]; then
				response=$(getFile "$projectId" "$path%2Fpackage-lock.json")
				httpStatus=$(getHttpStatus "$response")
				if [ "$httpStatus" = "200" ]; then
					packageLockContent=$(getHttpBody "$response")
					response=$(getFile "$projectId" "$path%2Fpackage.json")
					packageJsonContent=$(getHttpBody "$response")
					analyzePackageLockFile "$packageLockContent" "$packageJsonContent" "$projectName"
					packageFound=true
					echo "package-lock.json  is found in the /frontend"
				fi
			fi

			if [ "tree" == "$type" ] && [ ".gitlab" != "$name" ] && [ "deploy_utils" != "$name" ]; then
				nextLayerPaths+=("$path")
			fi
		done

		if [ "$composerFound" = true ] && [ "$packageFound" == true ]; then
			continue;
		fi
		# search composer.lock at the next layer
		for path in "${nextLayerPaths[@]}"; do
			if [ "$composerFound" = false ]; then
				response=$(getFile "$projectId" "$path%2Fcomposer.lock")
				httpStatus=$(getHttpStatus "$response")
				if [ "$httpStatus" = "200" ]; then
					fileContent=$(getHttpBody "$response")
					analyzeComposerLockFile "$fileContent" "$projectName"
					composerFound=true
					echo "composer.lock is found in the next layer"
					break;
				fi
			fi

			if [ "$packageFound" == false ]; then
				response=$(getFile "$projectId" "$path%2Fpackage-lock.json")
				httpStatus=$(getHttpStatus "$response")
				if [ "$httpStatus" = "200" ]; then
					packageLockContent=$(getHttpBody "$response")
					response=$(getFile "$projectId" "$path%2Fpackage.json")
					packageJsonContent=$(getHttpBody "$response")
					analyzePackageLockFile "$packageLockContent" "$packageJsonContent" "$projectName"
					packageFound=true
					echo "package-lock.json is found in the next layer"
				else
					response=$(getFile "$projectId" "$path%2Ffrontend%2Fpackage-lock.json")
					httpStatus=$(getHttpStatus "$response")
					if [ "$httpStatus" = "200" ]; then
						packageLockContent=$(getHttpBody "$response")
						response=$(getFile "$projectId" "$path%2Ffrontend%2Fpackage.json")
						packageJsonContent=$(getHttpBody "$response")
						analyzePackageLockFile "$packageLockContent" "$packageJsonContent" "$projectName"
						packageFound=true
						echo "package-lock.json is found in the next layer"
					fi
				fi
			fi
		done
	done

	let "page+=1"
done

printf "${GREEN}Download and scan successfully\n"

# combine all security report
# read project directory of the report folder
readarray -t projects < <(find report -maxdepth 1 -type d -printf '%P\n')

# combile json files of reports and key by the project name
composerReport="{"
npmReport="{"
for i in "${!projects[@]}"; do
	project="${projects[$i]}"

	if [ -z "$project" ]; then
		continue;
	fi

	composerReport+="\"$project\":"
	if [ -f "report/$project/npm-security-report.json" ]; then
		composerReport+=$(cat "report/$project/composer-security-report.json")
	else
		composerReport+="{}"
	fi

	npmReport+="\"$project\":"
	if [ -f "report/$project/npm-security-report.json" ]; then
		npmReport+=$(cat "report/$project/npm-security-report.json")
	else
		npmReport+="{}"
	fi

	index=$((i+1))
	if [ "$index" != ${#projects[@]} ]; then
		composerReport+=","
		npmReport+=","
	fi

done
composerReport+="}"
npmReport+="}"

echo "$composerReport" | jq '.' > security-scan-result-all.json
echo "$npmReport" | jq '.' > npm-scan-result-all.json

printf "${GREEN}Generate report successfully\n"