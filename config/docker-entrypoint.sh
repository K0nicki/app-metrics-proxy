#!/bin/bash -e

# Default http/-s, node exporter and cadvisor portsc
ports=(80 8080 9100)
metrics_path=$METRICS_PATH
SSH_OPTS=('UserKnownHostsFile=/dev/null' 'StrictHostKeyChecking=no' 'LogLevel=ERROR')
[[ -n $PORTS ]] && ports=(${ports[@]} ${PORTS})

# Run nginx
/usr/sbin/nginx &

# ssh server 
echo "root:$SSHPASS" | chpasswd
/usr/sbin/sshd -D &

getContainerNameByID() {
    docker ps -f "id=$1" --format "{{ .Names }}" | cut -d"_" -f2 |cut -d"." -f1
}

sleep 15    # All other app-metrics-proxy containers have to enter running state

# Update node IDs, containers in global mode
if [ $(docker info --format '{{.Swarm.ControlAvailable}}') == "true" ]; then
    unset allNodeIDs
    myNodeID=$(docker info -f '{{.Swarm.NodeID}}')
    allNodeIDs_tmp=$(docker service ps monitoring_app-metrics-proxy -q --filter "desired-state=Running" | xargs docker inspect --format 'monitoring_app-metrics-proxy.{{.NodeID}}.{{.ID}}')
    
    for i in $allNodeIDs_tmp; do
        result=$(echo $i |grep -v $myNodeID || exit 0)

        [[ -n $result ]] && allNodeIDs=(${allNodeIDs[@]} $result) && \
            $(sshpass -e ssh-copy-id $(for i in ${SSH_OPTS[@]}; do echo -n "-o $i "; done) -p 22 $result || exit 0) || \
            echo "Error during sending ssh-id to $result"

    done

    unset result
    unset myNodeID
    unset allNodeIDs_tmp
fi

while :; do
    start_time=$SECONDS # Tic
    containersIDs=$(docker ps -q)

    # Ingore all containers deployed in global mode, don't want to sync them
    if [ $(docker info --format '{{.Swarm.ControlAvailable}}') == "true" ]; then
        CONTAINERS_TO_EXCLUDE=$(docker service ls --format '{{.Name}}' --filter "mode=global")
    fi

    for container in $containersIDs; do
        for port in ${ports[@]}; do

            if [ $(curl -f -LI ${container}:${port}${metrics_path}/metrics -o /dev/null -w '%{http_code}\n' -s) == "200" ]; then
                found_port="true"

                # get container name and create dir for metrics
                containerName=$(getContainerNameByID $container)
                mkdir -p /tmp/metrics/$containerName

                # Collect metrics
                curl -s ${container}:${port}${metrics_path}/metrics > /tmp/metrics/$containerName/metrics

                # Logging
                echo "$(date -u): Collected metrics for \"$containerName\". Details: path: $([[ -n $metrics_path ]] && echo -n $metrics_path/metrics || echo -n "/metrics"; echo -n ", " )port: $port"
            fi
            
            [[ -n $found_port ]] && unset found_port && break
        done
    done
    
    # Update local metrics, rm tmp location
    cp -fR /tmp/metrics/* /var/www/html/
    rm -rf /tmp/metrics

    # Sync new data with other nodes
    # Notice that allNodeIDs array has entries only if node is a manager, so no neccessity to check if node is manager
    for node in ${allNodeIDs[@]}; do 
        $(
            sshpass -e \
            rsync -arquI \
            $(for excluded in ${CONTAINERS_TO_EXCLUDE[@]}; do echo -n "--exclude $(echo -n $excluded | cut -d"_" -f2 |cut -d"." -f1) "; done) --ignore-missing-args \
            -e "ssh $(for i in ${SSH_OPTS[@]}; do echo -n "-o $i "; done)" ${node}:/var/www/html/ /var/www/html/ || exit 0
        )

        $(
            sshpass -e \
            rsync -arquI \
            $(for excluded in ${CONTAINERS_TO_EXCLUDE[@]}; do echo -n "--exclude $(echo -n $excluded | cut -d"_" -f2 |cut -d"." -f1) "; done) --ignore-missing-args \
            -e "ssh $(for i in ${SSH_OPTS[@]}; do echo -n "-o $i "; done)" /var/www/html/ ${node}:/var/www/html/ || exit 0
        )     

        # Logging
        echo "$(date -u): Sent files to $node"

    done

    echo "Collected all metrics in $(( SECONDS - start_time))sec."; # Toc
    sleep $SCRAPE_INTERVAL
done
