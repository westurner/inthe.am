STARTING_DIR=$(pwd)
MAIN_DIR=/var/www/twweb
if [ ! -z "$TRAVIS" ]; then
    MAIN_DIR=$STARTING_DIR
fi

# Install necessary packages
apt-get update
apt-get install -y python-software-properties
apt-add-repository -y ppa:chris-lea/node.js
apt-get update
apt-get install -y git postgresql-server-dev-9.1 python-dev cmake build-essential uuid-dev gnutls-bin memcached redis-server chrpath git-core libssl-dev libfontconfig1-dev nodejs firefox checkinstall curl libcurl4-gnutls-dev libgnutls-dev

if [ -z "$TRAVIS" ]; then
    PHANTOMJS=phantomjs-1.9.7-linux-i686
    cd /usr/local/share/
    if [ ! -d $PHANTOMJS ]; then
        wget https://bitbucket.org/ariya/phantomjs/downloads/$PHANTOMJS.tar.bz2
        tar -xjf $PHANTOMJS.tar.bz2
        ln -s /usr/local/share/$PHANTOMJS/bin/phantomjs /usr/local/share/phantomjs; sudo ln -s /usr/local/share/$PHANTOMJS/bin/phantomjs /usr/local/bin/phantomjs; sudo ln -s /usr/local/share/$PHANTOMJS/bin/phantomjs /usr/bin/phantomjs
    fi
    cd $STARTING_DIR

    # Set up virtual environment
    mkdir -p /var/www/envs
    if [ ! -d /var/www/envs/twweb ]; then
        wget https://raw.github.com/pypa/pip/master/contrib/get-pip.py
        python get-pip.py
        pip install virtualenv
        virtualenv /var/www/envs/twweb
        printf "\n\nsource $MAIN_DIR/environment_variables.sh\n" >> /var/www/envs/twweb/bin/activate
        cp $MAIN_DIR/scripts/vagrant/environment_variables.sh $MAIN_DIR
    fi
    if [ ! -L $MAIN_DIR/bin ]; then
        ln -s /var/www/envs/twweb/bin $MAIN_DIR/bin
    fi

    # Copy bash profile into place
    cp $MAIN_DIR/scripts/vagrant/bash_profile /home/vagrant/.profile

    source $MAIN_DIR/environment_variables.sh
    source /var/www/envs/twweb/bin/activate
else
    source $MAIN_DIR/scripts/vagrant/environment_variables.sh
    source ~/virtualenv/python2.7/bin/activate
fi

mkdir -p $MAIN_DIR/task_data
mkdir -p $MAIN_DIR/logs

# Install Taskd and setup certificates
if [ ! -d $TWWEB_TASKD_DATA ]; then
    # See environment variable TWWEB_TASKD_DATA

    mkdir -p $TWWEB_TASKD_DATA/src
    cd $TWWEB_TASKD_DATA/src

    wget http://taskwarrior.org/download/taskd-1.0.0.tar.gz
    tar xzf taskd-1.0.0.tar.gz
    cd taskd-1.0.0

    which taskd
    if [ $? -ne 0 ]; then
        cmake .
        make
        checkinstall --default
        cp  /var/taskd/src/taskd-1.0.0/taskd_1.0.0-1*.deb /tmp
    fi


    cd $TWWEB_TASKD_DATA
    export TASKDDATA=$TWWEB_TASKD_DATA
    taskd init
    taskd add org inthe_am
    taskd add org testing
    cp $MAIN_DIR/scripts/vagrant/simple_taskd_upstart.conf /etc/init/taskd.conf

    if [ -z "$TRAVIS" ]; then
        service taskd stop
    fi

    # generate certificates
    cd $TWWEB_TASKD_DATA/src/taskd-1.0.0/pki
    ./generate
    cp client.cert.pem $TASKDDATA
    cp client.key.pem $TASKDDATA
    cp server.cert.pem $TASKDDATA
    cp server.key.pem $TASKDDATA
    cp server.crl.pem $TASKDDATA
    cp ca.cert.pem $TASKDDATA
    cp ca.key.pem $TASKDDATA

    cp $MAIN_DIR/scripts/vagrant/simple_taskd_configuration.conf /var/taskd/config
    cp $MAIN_DIR/scripts/vagrant/certificate_signing_template.template /var/taskd/cert.template

    sudo chown -R vagrant:vagrant $TASKDDATA

    if [ -z "$TRAVIS" ]; then
        service taskd start
    fi
fi

which task
if [ $? -ne 0 ]; then
    cd $TWWEB_TASKD_DATA/src
    wget http://taskwarrior.org/download/task-2.3.0.tar.gz
    tar xzf task-2.3.0.tar.gz
    cd task-2.3.0
    cmake .
    make
    checkinstall --default
    cp /var/taskd/src/task-2.3.0/task_2.3.0-1*.deb /tmp
fi

# copy MAIN_DIR into a temp folder and run npm there
# to avoid EPERM errors on NFS shared folders in vagrant
# See: https://github.com/npm/npm/issues/3565
cd $STARTING_DIR
cp -a $MAIN_DIR /tmp/twweb
chown -R vagrant. /tmp/twweb
cd /tmp/twweb

echo "installing ember-cli and bower"
npm install -g ember-cli bower
echo "running npm install"
npm install
echo "running bower install"
bower --config.interactive=false install --allow-root
echo "running ember install"
ember install
echo "running ember build"
ember build

# Sync back node_modules to original place
rsync --recursive --links --times /tmp/twweb/ $MAIN_DIR/
cd $MAIN_DIR

# Install requirements
source /var/www/envs/twweb/bin/activate
pip install --download-cache=/tmp/pip_cache -r $MAIN_DIR/requirements.txt

if [ -z "$TRAVIS" ]; then
    pip install ipdb
    python $MAIN_DIR/manage.py syncdb --noinput
    python $MAIN_DIR/manage.py migrate --noinput

    if [ ! -f /etc/init/taskd-celery.conf ]; then
        cp $MAIN_DIR/scripts/vagrant/simple_celery_upstart.conf /etc/init/taskd-celery.conf
        service taskd-celery start
    fi

    service taskd-celery restart
    service taskd restart
else
    if [ -d /home/travis/.config ]; then
        chmod -R 777 /home/travis/.config
    fi
fi
