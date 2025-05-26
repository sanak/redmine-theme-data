#!/usr/bin/env bash
# Ref: https://github.com/docker-library/redmine/blob/16b54a8b32b60af14af5917888e8abff62fffe2a/5.0/bookworm/docker-entrypoint.sh
set -Eeo pipefail
# TODO add "-u"

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

isLikelyRedmine=
case "$1" in
	rails | rake ) isLikelyRedmine=1 ;;
esac

_fix_permissions() {
	# https://www.redmine.org/projects/redmine/wiki/RedmineInstall#Step-8-File-system-permissions
	local dirs=( config log public/assets public/plugin_assets tmp ) args=()
	if [ "$(id -u)" = '0' ]; then
		args+=( ${args[@]:+,} '(' '!' -user redmine -exec chown redmine:redmine '{}' + ')' )

		# https://github.com/docker-library/redmine/issues/268 - scanning "files" might be *really* expensive, so we should skip it if it seems like it's "already correct"
		local filesOwnerMode
		filesOwnerMode="$(stat -c '%U:%a' files)"
		if [ "$filesOwnerMode" != 'redmine:755' ]; then
			dirs+=( files )
		fi
	fi
	# directories 755, files 644:
	args+=( ${args[@]:+,} '(' -type d '!' -perm 755 -exec sh -c 'chmod 755 "$@" 2>/dev/null || :' -- '{}' + ')' )
	args+=( ${args[@]:+,} '(' -type f '!' -perm 644 -exec sh -c 'chmod 644 "$@" 2>/dev/null || :' -- '{}' + ')' )
	find "${dirs[@]}" "${args[@]}"
}

# allow the container to be started with `--user`
if [ -n "$isLikelyRedmine" ] && [ "$(id -u)" = '0' ]; then
	_fix_permissions
	# for storybook (enable faketime)
	# exec gosu redmine "$BASH_SOURCE" "$@"
fi

if [ -n "$isLikelyRedmine" ]; then
	_fix_permissions
	if [ ! -f './config/database.yml' ]; then
		# for storybook (support only sqlite3)
		adapter='sqlite3'
		host='localhost'
		file_env 'REDMINE_DB_PORT' ''
		file_env 'REDMINE_DB_USERNAME' 'redmine'
		file_env 'REDMINE_DB_PASSWORD' ''
		file_env 'REDMINE_DB_DATABASE' 'sqlite/redmine.db'
		file_env 'REDMINE_DB_ENCODING' 'utf8'

		mkdir -p "$(dirname "$REDMINE_DB_DATABASE")"
		if [ "$(id -u)" = '0' ]; then
			find "$(dirname "$REDMINE_DB_DATABASE")" \! -user redmine -exec chown redmine '{}' +
		fi

		REDMINE_DB_ADAPTER="$adapter"
		REDMINE_DB_HOST="$host"
		echo "$RAILS_ENV:" > config/database.yml
		for var in \
			adapter \
			host \
			port \
			username \
			password \
			database \
			encoding \
		; do
			env="REDMINE_DB_${var^^}"
			val="${!env}"
			[ -n "$val" ] || continue
			if [ "$var" != 'adapter' ]; then
				# https://github.com/docker-library/redmine/issues/353 🙃
				val='"'"$val"'"'
				# (only add double quotes to every value *except* `adapter: xxx`)
			fi
			echo "  $var: $val" >> config/database.yml
		done
	fi

	# install additional gems for Gemfile.local and plugins
	bundle check || bundle install

	file_env 'REDMINE_SECRET_KEY_BASE'
	# just use the rails variable rather than trying to put it into a yml file
	# https://github.com/rails/rails/blob/6-1-stable/railties/lib/rails/application.rb#L438
	# https://github.com/rails/rails/blob/1aa9987169213ce5ce43c20b2643bc64c235e792/railties/lib/rails/application.rb#L484 (rails 7.1-stable)
	if [ -n "${SECRET_KEY_BASE}" ] && [ -n "${REDMINE_SECRET_KEY_BASE}" ]; then
		echo >&2
		echo >&2 'warning: both SECRET_KEY_BASE and REDMINE_SECRET_KEY_BASE{_FILE} set, only SECRET_KEY_BASE will apply'
		echo >&2
	fi
	: "${SECRET_KEY_BASE:=$REDMINE_SECRET_KEY_BASE}"
	export SECRET_KEY_BASE
	# generate SECRET_KEY_BASE if not set; this is not recommended unless the secret_token.rb is saved when container is recreated
	if [ -z "$SECRET_KEY_BASE" ] && [ ! -f config/initializers/secret_token.rb ]; then
		echo >&2 'warning: no *SECRET_KEY_BASE set; running `rake generate_secret_token` to create one in "config/initializers/secret_token.rb"'
		unset SECRET_KEY_BASE # just in case
		rake generate_secret_token
	fi

	if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
		rake db:migrate
	fi

	if [ "$1" != 'rake' -a -n "$REDMINE_PLUGINS_MIGRATE" ]; then
		rake redmine:plugins:migrate
	fi

	# for storybook (load customized fixtures)
	rake db:fixtures:load FIXTURES_PATH=./fixtures

	# remove PID file to enable restarting the container
	rm -f tmp/pids/server.pid
fi

exec "$@"
