#!/usr/bin/env bash

MIDO_DIR=$(pwd)
DEVSTACK_DIR="$MIDO_DIR/devstack"

source $MIDO_DIR/functions

# Midonet password. Used to simplify the passwords in the configurated localrc
MIDOSTACK_PASSWORD=${MIDOSTACK_PASSWORD:-gogomid0}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-$MIDOSTACK_PASSWORD}

# Setting this value as 'false' will deploy a devstack with quantum and openvsitch
USE_MIDONET=${USE_MIDONET:-true}

# Destination directory
DEST=${DEST:-/opt/stack}

# First configuration file is our own 'localrc'
if [ -f $MIDO_DIR/localrc ]; then
    source $MIDO_DIR/localrc
fi


if [ $USE_MIDONET = true ]; then
    # Then load the midonetrc
    source $MIDO_DIR/midonetrc

    # Set fixed and floating range here so we can make sure not to use addresses
    # from either range when attempting to guess the IP to use for the host.
    # Note that setting FIXED_RANGE may be necessary when running DevStack
    # in an OpenStack cloud that uses either of these address ranges internally.
    FLOATING_RANGE=${FLOATING_RANGE:-172.24.4.224/28}
    FIXED_RANGE=${FIXED_RANGE:-10.0.0.0/24}
    FIXED_NETWORK_SIZE=${FIXED_NETWORK_SIZE:-256}

    HOST_IP=$(get_default_host_ip $FIXED_RANGE $FLOATING_RANGE "$HOST_IP_IFACE" "$HOST_IP")
    if [ "$HOST_IP" == "" ]; then
        die $LINENO "Could not determine host ip address. Either localrc specified dhcp on ${HOST_IP_IFACE} or defaulted"
    fi
    KEYSTONE_AUTH_HOST=${KEYSTONE_AUTH_HOST:-$HOST_IP}

    # apt package pinning (zookeeper 3.4.5, ovs-dp 1.10)
    UBUNTU_ARCHIVE="http://us.archive.ubuntu.com/ubuntu/"
    RARING_SRC="deb $UBUNTU_ARCHIVE raring universe\ndeb-src $UBUNTU_ARCHIVE raring universe"
    RARING_LIST_FILE=/etc/apt/sources.list.d/raring.list
    if [ ! -f $RARING_LIST_FILE ]; then
        echo "Adding sources from Ubuntu Raring release"
        echo -e $RARING_SRC | sudo tee $RARING_LIST_FILE
    fi

    SAUCY_SRC="deb $UBUNTU_ARCHIVE saucy universe\ndeb-src $UBUNTU_ARCHIVE saucy universe"
    SAUCY_LIST_FILE=/etc/apt/sources.list.d/saucy.list
    if [ ! -f $SAUCY_LIST_FILE ]; then
        echo "Adding sources from Ubuntu Saucy release"
        echo -e $SAUCY_SRC | sudo tee $SAUCY_LIST_FILE
    fi

    CASSANDRA_LIST_FILE=/etc/apt/sources.list.d/cassandra.list
    if [ ! -f $CASSANDRA_LIST_FILE ]; then 
        echo "Adding Cassandra sources"
        echo -e 'deb http://www.apache.org/dist/cassandra/debian 11x main\ndeb-src http://www.apache.org/dist/cassandra/debian 11x main' | sudo tee $CASSANDRA_LIST_FILE
        sudo gpg --keyserver pgp.mit.edu --recv-keys F758CE318D77295D
        sudo gpg --export --armor F758CE318D77295D | sudo apt-key add -
        sudo gpg --keyserver pgp.mit.edu --recv-keys 2B5C1B00
        sudo gpg --export --armor 2B5C1B00 | sudo apt-key add -
    fi

    sudo cp $MIDO_DIR/config_files/01midokura_apt_config /etc/apt/apt.conf.d/
    sudo cp $MIDO_DIR/config_files/01midokura_apt_preferences /etc/apt/preferences.d/

    sudo apt-get -y update

    # Install dependences
    sudo apt-get install -y python-dev libxml2-dev libxslt-dev openjdk-7-jdk openjdk-7-jre zookeeper zookeeperd cassandra openvswitch-datapath-dkms linux-headers-`uname -r` maven screen

    # Stop service zookeeper temporaly
    sudo service zookeeper stop

    # Configure casandra
    sudo service cassandra stop
    sudo chown cassandra:cassandra /var/lib/cassandra
    sudo rm -rf /var/lib/cassandra/data/system/LocationInfo
    # Configure Cassandra and restart
    CASSANDRA_FILE='/etc/cassandra/cassandra.yaml'
    sudo sed -i -e "s/^cluster_name:.*$/cluster_name: \'midonet\'/g" $CASSANDRA_FILE
    CASSANDRA_ENV_FILE='/etc/cassandra/cassandra-env.sh'
    sudo sed -i 's/\(MAX_HEAP_SIZE=\).*$/\1128M/' $CASSANDRA_ENV_FILE
    sudo sed -i 's/\(HEAP_NEWSIZE=\).*$/\164M/' $CASSANDRA_ENV_FILE
    # Cassandra seems to need at least 228k stack working with Java 7.
    # Related bug: https://issues.apache.org/jira/browse/CASSANDRA-5895
    sudo sed -i -e "s/-Xss180k/-Xss228k/g" $CASSANDRA_ENV_FILE
    sudo service cassandra start

    # Maven installs Java 6; make sure we set Java 7 as primary
    # JDK so that MidoNet Maven build works
    sudo update-java-alternatives -s java-1.7.0-openjdk-amd64

    # Create the dest dir in case it doesn't exist
    # Github clone will fail to run otherwise
    if [ ! -d $MIDO_DEST ]; then
        echo "Creating midonet destination directory... $MIDO_DEST"
        sudo mkdir -p $MIDO_DEST
        sudo chown -R ubuntu:ubuntu $DEST
    fi

    # Check if we have zinc installed
    ZINC_DIR=$MIDO_DEST/zinc
    if [ ! -d $ZINC_DIR ]; then
        ZINC_FILE_NAME=${ZINC_URL##*/}
        ZINC_FILE=$MIDO_DEST/$ZINC_FILE_NAME
        if [ -f $ZINC_FILE ]; then
            rm -f $ZINC_FILE
        fi
        sudo wget -c $ZINC_URL -O $ZINC_FILE
        echo "Downloading zinc from $ZINC_URL to $ZINC_FILE"
        sudo tar -zxf $ZINC_FILE -C "$MIDO_DEST"
        ZINC_DIR_NAME=${ZINC_FILE_NAME%%.tgz}
        ZINC_TMP_DIR=$MIDO_DEST/$ZINC_DIR_NAME
        sudo mv $ZINC_TMP_DIR $ZINC_DIR
        sudo rm $ZINC_FILE
    fi

    # Start zinc, restart if running
    if is_running "zinc"
    then
        echo "Stopping zinc"
        $ZINC_DIR/bin/zinc -shutdown
    fi

    echo "Starting zinc"
    $ZINC_DIR/bin/zinc -start

    MIDONET_SRC_DIR=$MIDO_DEST/midonet


    # Get MidoNet source and install
    if [ ! -d "$MIDONET_SRC_DIR" ]; then
        git_clone $MIDONET_GIT_REPO $MIDONET_SRC_DIR $MIDONET_GIT_BRANCH
        if [ $? -gt 0 ]
        then
            echo $?
            echo "Exiting. Cloning MidoNet git repo $MIDONET_GIT_REPO (branch $MIDONET_GIT_BRANCH) failed, please check if environment variable MIDONET_GIT_REPO and MIDONET_GIT_BRANCH."
            exit 1
        fi
    fi

    # Set up web.xml for midonet-api
    MIDONET_API_CFG=$MIDONET_SRC_DIR/midonet-api/src/main/webapp/WEB-INF/web.xml
    cp $MIDONET_API_CFG.dev $MIDONET_API_CFG
    # TODO(ryu): Improve this part
    sed -i -e "s/999888777666/$PASSWORD/g" $MIDONET_API_CFG
    sed -i -e "s/mido_admin/admin/g" $MIDONET_API_CFG
    sed -i -e "s/mido_tenant_admin/Member/g" $MIDONET_API_CFG
    sed -i -e "s/mido_tenant_user/Member/g" $MIDONET_API_CFG
    sed -i -e "s/org.midonet.api.auth.MockAuthService/org.midonet.api.auth.keystone.v2_0.KeystoneService/g" $MIDONET_API_CFG
    sed -i -e "/<param-name>keystone-service_host<\/param-name>/{n;s%.*%    <param-value>$KEYSTONE_AUTH_HOST</param-value>%g}" $MIDONET_API_CFG
    sed -i -e "/<param-name>keystone-admin_token<\/param-name>/{n;s%.*%    <param-value>$ADMIN_PASSWORD</param-value>%g}" $MIDONET_API_CFG

    # Build midolman
    if $MIDO_MVN_CLEAN ; then
        cd $MIDONET_SRC_DIR && mvn clean install -DskipTests -PfatJar
    else
        cd $MIDONET_SRC_DIR && mvn install -DskipTests -PfatJar
    fi

    MIDOLMAN_TGT_DIR="$MIDONET_SRC_DIR/midolman/target"
    MIDOLMAN_JAR_FILE="$MIDOLMAN_TGT_DIR/midolman-$MIDOLMAN_BUNDLE_VERSION-jar-with-dependencies.jar"
    echo "midolman-jar-file is $MIDOLMAN_JAR_FILE"
    mvn install:install-file -Dfile="$MIDOLMAN_JAR_FILE" \
                             -DgroupId=org.midonet \
                             -DartifactId=midolman-with-dependencies \
                             -Dversion=$MIDOLMAN_BUNDLE_VERSION \
                             -Dpackaging=jar
    if [ $? -gt 0 ]
    then
        echo "Exiting. MidoNet Maven install failed."
        exit 1
    fi

    ##### Setup to allow mm-dpctl and mm-ctl to run in devstack ####

    # Place our executables in /usr/local/bin
    LOCAL_BIN_DIR=/usr/local/bin/
    sudo cp $MIDO_DIR/scripts/binproxy $LOCAL_BIN_DIR/mm-ctl
    sudo cp $MIDO_DIR/scripts/binproxy $LOCAL_BIN_DIR/mm-dpctl

    # Jars have been created in earlier build step, put them all in one deps dir
    MIDONET_DEPS_DIR=$MIDONET_SRC_DIR/midodeps
    mkdir -p $MIDONET_DEPS_DIR
    cp $MIDOLMAN_TGT_DIR/midolman-*.jar $MIDONET_DEPS_DIR/midolman.jar
    cp $MIDONET_SRC_DIR/midonet-jdk-bootstrap/target/midonet-jdk-bootstrap-*.jar $MIDONET_DEPS_DIR/midonet-jdk-bootstrap.jar
    cp -r $MIDOLMAN_TGT_DIR/dep $MIDONET_DEPS_DIR/

    # Change MIDO_HOME (used by mm-ctl / mm-dpctl) to point at deps dir
    export MIDO_HOME=$MIDONET_DEPS_DIR

    # Create the midolman dir in case it doesn't exist
    # Midolman will fail to run otherwise
    if [ ! -d $MIDOLMAN_CONF_DIR ]; then
        sudo mkdir -p $MIDOLMAN_CONF_DIR
    fi
    # These config files are needed - create if not present
    if [ ! -f $MIDOLMAN_CONF_DIR/logback-dpctl.xml ]; then
        sudo cp $MIDONET_SRC_DIR/midolman/conf/logback-dpctl.xml $MIDOLMAN_CONF_DIR/
    fi
    if [ ! -f $MIDOLMAN_CONF_DIR/midolman.conf ]; then
        sudo cp $MIDONET_SRC_DIR/midolman/conf/midolman.conf $MIDOLMAN_CONF_DIR/
    fi

    # Start midonet-api and midolman in a screen
    # TODO: Set up midolman.conf properly as well in midolman/conf of Maven.
    # Still TODO?? we will see..
    # Restart ZK
    stop_service zookeeper
    start_service zookeeper
    if [ $? -gt 0 ]
    then
        echo "Exiting. Zookeeper service failed to start. Check that it has been installed correctly (dpkg -l | grep zookeeper)."
        echo "Otherwise, check if there may be a zombie zookeeper process running (use ps -ef | grep zookeeper)."
        exit 1
    fi

    # Restart Cassandra
    stop_service cassandra
    start_service cassandra
    if [ $? -gt 0 ]
    then
        echo "Exiting. Cassandra service failed to start. Check that it has been installed correctly (dpkg -l | grep cassandra)."
        echo "Otherwise, check if there may be a zombie Cassandra process running (use ps -ef | grep cassandra)."
        exit 1
    fi

    MIDO_SCREEN_EXISTS=$(screen -ls | egrep "[0-9].$MIDONET_SCREEN_NAME")
    if [[ $MIDO_SCREEN_EXISTS == '' ]]; then
        USE_MIDO_SCREEN=$(trueorfalse True $USE_MIDO_SCREEN)
        if [[ "$USE_MIDO_SCREEN" == "True" ]]; then
            # Create a new named screen to run processes in
            screen -d -m -S $MIDONET_SCREEN_NAME -t shell -s /bin/bash
            sleep 1

            # Set a reasonable status bar
            if [ -z "$MIDO_SCREEN_HARDSTATUS" ]; then
                MIDO_SCREEN_HARDSTATUS='%{= .} %-Lw%{= .}%> %n%f %t*%{= .}%+Lw%< %-=%{g}(%{d}%H/%l%{g})'
            fi
            screen -r $MIDONET_SCREEN_NAME -X hardstatus alwayslastline "$MIDO_SCREEN_HARDSTATUS"
            screen -r $MIDONET_SCREEN_NAME -X setenv PROMPT_COMMAND /bin/true
        fi

        # Clear screen rc file
        MIDO_SCREENRC=$MIDO_TOP_DIR/../$MIDONET_SCREEN_NAME-screenrc
        if [[ -e $MIDO_SCREENRC ]]; then
            rm -f $MIDO_SCREENRC
        fi
    else
        echo "You are already running a mido session."
        echo "To rejoin this session type 'screen -x mido'."
        echo "To destroy this session, type './midonet_unstack.sh'."
        exit 1
    fi

    # Make sure to load ovs kmod
    sudo modprobe openvswitch

    enable_service midolman midonet-api

    # Midolman service must be stopped
    echo "Starting midolman"

    SCREEN_NAME=$MIDONET_SCREEN_NAME
    TOP_DIR=$MIDO_DIR

    MIDONET_API_PORT=${MIDONET_API_PORT:-8081}
    MIDONET_API_URI=${MIDONET_API_URI:-http://$HOST_IP:$MIDONET_API_PORT/midonet-api}
    screen_it midolman "cd $MIDONET_SRC_DIR && mvn -pl midolman exec:exec"
    # Run the API with jetty:plugin
    # Tomcat need to be stopped
    echo "Starting midonet-api"
    screen_it midonet-api "cd $MIDONET_SRC_DIR && mvn -pl midonet-api jetty:run -Djetty.port=$MIDONET_API_PORT"

    echo "* Making sure MidoNet API server is up and ready."
    STARTUPTIME=0
    CONNECTED=1

    while [ $CONNECTED -ne 0 ]
      do
        curl -fs $MIDONET_API_URI > /dev/null
        let CONNECTED=$?
        echo "Waiting for API server to start, may take some time. Have waited $STARTUPTIME seconds so far."
        sleep 2
        let STARTUPTIME=STARTUPTIME+2
    done

    echo "* API server is up, took $STARTUPTIME seconds"
fi

# Execute stack scri
cp $MIDO_DIR/devstackrc $DEVSTACK_DIR/localrc
cd $DEVSTACK_DIR && source stack.sh

if [ $USE_MIDONET = true ]; then
    # Add a filter to allow rootwrap to use mm-ctl from /usr/local/bin/
    sudo cp $MIDO_DIR/config_files/midonet_devstack.filters /etc/nova/rootwrap.d/

    if [ -f /etc/libvirt/qemu.conf ]; then

        # Copy the file for backup purposes
        sudo cp /etc/libvirt/qemu.conf /etc/libvirt/qemu.conf.bak

        # Change libvirt config file for qemu to allow "ethernet" mode.
        sudo sed -i -e 's/#user/user/'  -e 's/#group/group/'  -e 's/.*\(clear_emulator_capabilities =\) 1/\1 0/' /etc/libvirt/qemu.conf
        grep  -q '^cgroup_device_acl' /etc/libvirt/qemu.conf |R| cat <<EOF | sudo tee -a /etc/libvirt/qemu.conf && sudo service libvirt-bin restart
    cgroup_device_acl = [
           "/dev/null", "/dev/full", "/dev/zero",
           "/dev/random", "/dev/urandom",
           "/dev/ptmx", "/dev/kvm", "/dev/kqemu",
           "/dev/rtc", "/dev/hpet", "/dev/net/tun",
    ]
EOF
    fi
fi