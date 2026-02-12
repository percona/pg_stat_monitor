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

    pst)
        echo "Installing Percona Server for PostgreSQL"
        sudo wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        sudo dpkg -i percona-release_latest.generic_all.deb
        sudo percona-release setup ppg-${2}
        sudo apt update -y
        sudo apt install -y percona-postgresql-${2} percona-postgresql-server-dev-${2}
        ;;

    *)
        echo "Unknown PostgreSQL distribution type: $1"
        echo "Please use one of the following: pgdg, ppg"
        exit 1
        ;;
esac

