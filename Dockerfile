FROM  neo4j:3.5.19-enterprise

RUN apt update && apt install -y --no-install-recommends \
	curl \
	zip \
	unzip \
	netcat \
	awscli \
	jq lsof host \
	logrotate

# Install plugins
RUN mkdir -p /var/lib/neo4j/plugins

ENV NEO4J_APOC_VERSION=3.5.0.12

RUN curl -L -s https://github.com/neo4j-contrib/neo4j-apoc-procedures/releases/download/$NEO4J_APOC_VERSION/apoc-$NEO4J_APOC_VERSION-all.jar \
	> /var/lib/neo4j/plugins/apoc-$NEO4J_APOC_VERSION-all.jar && \
	curl -L -s https://repo1.maven.org/maven2/mysql/mysql-connector-java/6.0.6/mysql-connector-java-6.0.6.jar \
	> /var/lib/neo4j/plugins/mysql-connector-java-6.0.6.jar && \
	chown -R neo4j:neo4j /var/lib/neo4j/plugins/ 

ENV EXTENSION_SCRIPT=/ecs-extension.sh

COPY ecs-extension.sh ${EXTENSION_SCRIPT}
COPY init-db.sh healthcheck.sh /

# These were created earlier by image, but we dont need them since
# entrypoint will configure Neo to use them if they exist.
RUN rm -rf ${NEO4J_HOME}/data/ ${NEO4J_HOME}/logs/ ${NEO4J_HOME}/metrics/

EXPOSE 5000 5001 6000 6001 7000

CMD ["start"]