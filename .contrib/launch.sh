#!/bin/sh

. /usr/local/dynamic-resources/dynamic_resources.sh

# Arguments:
# $1 - datasource jndi name
# $2 - datasource username
# $3 - datasource password
# $4 - datasource driver
# $5 - datasource url
function generate_datasource() {
  ds="    <Resource name=\"$1\" auth=\"Container\" type=\"javax.sql.DataSource\" username=\"$2\" password=\"$3\" driverClassName=\"$4\" url=\"$5\" maxWait=\"10000\" maxIdle=\"30\" validationQuery=\"SELECT 1\" testWhenIdle=\"true\" testOnBorrow=\"true\" factory=\"org.apache.tomcat.jdbc.pool.DataSourceFactory\""
  if [ -n "$tx_isolation" ]; then
    ds="$ds defaultTransactionIsolation=\"$tx_isolation\""
  fi
  if [ -n "$min_pool_size" ]; then
    ds="$ds minIdle=\"$min_pool_size\""
  fi
  if [ -n "$max_pool_size" ]; then
    ds="$ds maxActive=\"$max_pool_size\""
  fi
  ds="$ds />"

  echo "$ds"
}

# Finds the environment variable  and returns its value if found.
# Otherwise returns the default value if provided.
#
# Arguments:
# $1 env variable name to check
# $2 default value if environemnt variable was not set
function find_env() {
  var=`printenv "$1"`

  # If environment variable exists
  if [ -n "$var" ]; then
    echo $var
  else
    echo $2
  fi
}

# Finds the name of the database services and generates data sources
# based on this info
function inject_datasources() {
  datasources=""

  # Find all databases in the $DB_SERVICE_PREFIX_MAPPING separated by ","
  IFS=',' read -a db_backends <<< $DB_SERVICE_PREFIX_MAPPING

  for db_backend in ${db_backends[@]}; do

    service_name=${db_backend%=*}
    service=${service_name^^}
    service=${service//-/_}
    db=${service##*_}
    prefix=${db_backend#*=}

    host=$(find_env "${service}_SERVICE_HOST")
    port=$(find_env "${service}_SERVICE_PORT")

    if [ "$db" = "MYSQL" ] || [ "$db" = "POSTGRESQL" ]; then
      configurable_db=true
    else
      configurable_db=false
    fi

    if [ "$configurable_db" = true ]; then
      if [ -z $host ] || [ -z $port ]; then
        echo "There is a problem with your service configuration!"
        echo "You provided following database mapping (via DB_SERVICE_PREFIX_MAPPING environment variable): $db_backend. To configure datasources we expect ${service}_SERVICE_HOST and ${service}_SERVICE_PORT to be set."
        echo
        echo "Current values:"
        echo
        echo "${service}_SERVICE_HOST: $host"
        echo "${service}_SERVICE_PORT: $port"
        echo
        echo "Please make sure you provided correct service name and prefix in the mapping. Additionally please check that you do not set portalIP to None in the $service_name service. Headless services are not supported at this time."
        echo
        echo "WARNING! The ${db,,} datasource for $prefix service WILL NOT be configured."
        continue
      fi

      # Custom JNDI environment variable name format: [NAME]_[DATABASE_TYPE]_JNDI
      jndi=$(find_env "${prefix}_JNDI" "jboss/datasources/${service,,}")

      # Database username environment variable name format: [NAME]_[DATABASE_TYPE]_USERNAME
      username=$(find_env "${prefix}_USERNAME")

      # Database password environment variable name format: [NAME]_[DATABASE_TYPE]_PASSWORD
      password=$(find_env "${prefix}_PASSWORD")

      # Database name environment variable name format: [NAME]_[DATABASE_TYPE]_DATABASE
      database=$(find_env "${prefix}_DATABASE")

      if [ -z $jndi ] || [ -z $username ] || [ -z $password ] || [ -z $database ]; then
        echo "Ooops, there is a problem with the ${db,,} datasource!"
        echo "In order to configure ${db,,} datasource for $prefix service you need to provide following environment variables: ${prefix}_USERNAME, ${prefix}_PASSWORD, ${prefix}_DATABASE."
        echo
        echo "Current values:"
        echo
        echo "${prefix}_USERNAME: $username"
        echo "${prefix}_PASSWORD: $password"
        echo "${prefix}_DATABASE: $database"
        echo
        echo "WARNING! The ${db,,} datasource for $prefix service WILL NOT be configured."
        continue
      fi

      # Transaction isolation level environment variable name format: [NAME]_[DATABASE_TYPE]_TX_ISOLATION
      tx_isolation=$(find_env "${prefix}_TX_ISOLATION")

      # min pool size environment variable name format: [NAME]_[DATABASE_TYPE]_MIN_POOL_SIZE
      min_pool_size=$(find_env "${prefix}_MIN_POOL_SIZE")

      # max pool size environment variable name format: [NAME]_[DATABASE_TYPE]_MAX_POOL_SIZE
      max_pool_size=$(find_env "${prefix}_MAX_POOL_SIZE")

      url="jdbc:${db,,}://$(find_env "${service}_SERVICE_HOST"):$(find_env "${service}_SERVICE_PORT")/$database"

      if [ "$db" = "MYSQL" ]; then
        driver="com.mysql.jdbc.Driver"
      elif [ "$db" = "POSTGRESQL" ]; then
        driver="org.postgresql.Driver"
      fi

      datasources="$datasources$(generate_datasource $jndi $username $password $driver $url)\n\n"
    fi
  done

  sed -i "s|<!-- ##DATASOURCES## -->|$datasources|" $CATALINA_HOME/conf/context.xml
}

function configure_administration() {
  if [ -n "${CATALINA_ADMIN_PASSWORD+_}" ]; then
      # default management username 'admin'
      CATALINA_ADMIN_USERNAME=${CATALINA_ADMIN_USERNAME:-admin}
      sed -i "/username=\"${CATALINA_ADMIN_USERNAME}\"/d" $CATALINA_HOME/conf/tomcat-users.xml
      sed -i -e"s#</tomcat-users>#\n<user username=\"${CATALINA_ADMIN_USERNAME}\" password=\"${CATALINA_ADMIN_PASSWORD}\" roles=\"manager-jmx,manager-script\"/>\n</tomcat-users>#" $CATALINA_HOME/conf/tomcat-users.xml
  fi
}

function configure_https() {
  https="<!-- No HTTPS configuration discovered -->"
  if [ -n "${CATALINA_HTTPS_CERTIFICATE_DIR}" -a -n "${CATALINA_HTTPS_CERTIFICATE}" -a -n "${CATALINA_HTTPS_CERTIFICATE_KEY}" ] ; then
      password=""
      if [ -n "${CATALINA_HTTPS_CERTIFICATE_PASSWORD}" ] ; then
          password=" SSLPassword=\"${CATALINA_HTTPS_CERTIFICATE_PASSWORD}\" "
      fi
      https="<Connector \
             protocol=\"org.apache.coyote.http11.Http11AprProtocol\" \
             port=\"8443\" maxThreads=\"200\" \
             scheme=\"https\" secure=\"true\" SSLEnabled=\"true\" \
             SSLCertificateFile=\"${CATALINA_HTTPS_CERTIFICATE_DIR}/${CATALINA_HTTPS_CERTIFICATE}\" \
             SSLCertificateKeyFile=\"${CATALINA_HTTPS_CERTIFICATE_DIR}/${CATALINA_HTTPS_CERTIFICATE_KEY}\" \
             ${password}  \
             SSLVerifyClient=\"optional\" SSLProtocol=\"TLSv1+TLSv1.1+TLSv1.2\"/>"
  elif [ -n "${CATALINA_HTTPS_CERTIFICATE_DIR}" -o -n "${CATALINA_HTTPS_CERTIFICATE}" -o -n "${CATALINA_HTTPS_CERTIFICATE_KEY}" ] ; then
      echo "WARNING! Partial HTTPS configuration, the https connector WILL NOT be configured."
  fi
  sed -i "s|### HTTPS_CONNECTOR ###|${https}|" $CATALINA_HOME/conf/server.xml
}

# user-overrideable, defaults to jdbc/auth
CATALINA_REALM_DATASOURCE_NAME="${CATALINA_REALM_DATASOURCE_NAME:-jdbc/auth}"

configure_realms() {
  realms="<!-- no additional realms configured -->"
  if [ -n "$CATALINA_REALM_USERTABLE" -a -n "$CATALINA_REALM_USERNAME_COL" -a -n "$CATALINA_REALM_USERCRED_COL" -a -n "$CATALINA_REALM_USERROLE_TABLE" -a -n "$CATALINA_REALM_ROLENAME_COL" ]; then
      realms="<Realm \
        className=\"org.apache.catalina.realm.DataSourceRealm\"\
        userTable=\"$CATALINA_REALM_USERTABLE\"\
        userNameCol=\"$CATALINA_REALM_USERNAME_COL\"\
        userCredCol=\"$CATALINA_REALM_USERCRED_COL\"\
        userRoleTable=\"$CATALINA_REALM_USERROLE_TABLE\"\
        roleNameCol=\"$CATALINA_REALM_ROLENAME_COL\"\
        dataSourceName=\"$CATALINA_REALM_DATASOURCE_NAME\"\
        localDataSource=\"true\"\
      />" # ^ must match a Resource definition. TODO: check that there is one.
  elif [ -n "$CATALINA_REALM_USERTABLE" -o -n "$CATALINA_REALM_USERNAME_COL" -o -n "$CATALINA_REALM_USERCRED_COL" -o -n "$CATALINA_REALM_USERROLE_TABLE" -o -n "$CATALINA_REALM_ROLENAME_COL" ]; then
      echo "WARNING! Partial Realm configuration, additional realms WILL NOT be configured."
  fi
  sed -i "s|<!--### ADDITIONAL_REALMS ###-->|$realms|" $CATALINA_HOME/conf/server.xml
}

expand_catalina_opts() {
    CATALINA_OPTS="$CATALINA_OPTS $CATALINA_OPTS_APPEND -javaagent:$CATALINA_HOME/lib/jolokia.jar=port=8778,protocol=https,caCert=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt,clientPrincipal=cn=system:master-proxy,useSslClientAuthentication=true,extraClientCheck=true,host=0.0.0.0,discoveryEnabled=false"

    MAX_HEAP=`get_heap_size`
    if [ -n "$MAX_HEAP" ]; then
      CATALINA_OPTS="$CATALINA_OPTS -Xms${MAX_HEAP}m -Xmx${MAX_HEAP}m"
    fi

    export CATALINA_OPTS
}

inject_datasources
configure_administration
configure_https
configure_realms
expand_catalina_opts

echo "Running $TOMCAT_IMAGE_NAME image, version $TOMCAT_VERSION"

exec $CATALINA_HOME/bin/catalina.sh run
