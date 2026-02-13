set -e

if [ -z "$2" ]; then
    echo "Error: The second argument (PostgreSQL version) must be provided."
    exit 1
fi


case "$1" in
    pgdg)
        echo "Installing PostgreSQL from PostgreSQL Global Development Group (PGDG) Distribution"
        sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt \
            $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        sudo wget --quiet -O - \
            https://www.postgresql.org/media/keys/ACCC4CF8.asc |
            sudo apt-key add -
        sudo apt update -y
        sudo apt -y install postgresql-${2} postgresql-server-dev-${2}
        ;;

    psp)
        echo "Installing Percona Server for PostgreSQL"
        sudo wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        sudo dpkg -i percona-release_latest.generic_all.deb
        sudo percona-release setup ppg-${2}
        sudo apt update -y
        sudo apt install -y percona-postgresql-${2} \
            percona-postgresql-contrib percona-postgresql-server-dev-${2} \
            percona-pgpool2 libpgpool2 percona-postgresql-${2}-pgaudit \
            percona-postgresql-${2}-pgaudit-dbgsym percona-postgresql-${2}-repack \
            percona-postgresql-${2}-repack-dbgsym percona-pgaudit${2}-set-user \
            percona-pgaudit${2}-set-user-dbgsym percona-postgresql-${2}-postgis-3 \
            percona-postgresql-${2}-postgis-3-scripts \
            percona-postgresql-postgis-scripts percona-postgresql-postgis \
            percona-postgis
        ;;

    *)
        echo "Unknown PostgreSQL distribution type: $1"
        echo "Please use one of the following: pgdg, psp"
        exit 1
        ;;
esac
