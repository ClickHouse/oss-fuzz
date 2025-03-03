#!/bin/bash -eu
# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

PROJECT=cxf
PROJECT_GROUP_ID=org.apache.cxf
PROJECT_ARTIFACT_ID=cxf
MAIN_REPOSITORY=https://github.com/apache/cxf/

MAVEN_ARGS="-Djavac.src.version=17 -Djavac.target.version=17 -Denforcer.skip=true -DskipTests"

function set_project_version_in_fuzz_targets_dependency {
  PROJECT_VERSION=$(cd $PROJECT && $MVN org.apache.maven.plugins:maven-help-plugin:3.2.0:evaluate -Dexpression=project.version -q -DforceStdout)
  FUZZ_TARGET_DEPENDENCIES=":cxf-core :cxf-rt-frontend-jaxrs :cxf-rt-transports-http :cxf-rt-rs-client :cxf-rt-rs-json-basic"
  
  for dependency in $FUZZ_TARGET_DEPENDENCIES; do
    # set dependency project version in fuzz-targets
    (cd fuzz-targets && $MVN versions:use-dep-version -Dincludes=$PROJECT_GROUP_ID$dependency -DdepVersion=$PROJECT_VERSION -DforceVersion=true)
  done
}

cd project-parent

# LOCAL_DEV env variable need to be set in local development env
if [[ -v LOCAL_DEV ]]; then
  MVN=mvn

  # checkout latest project version
  git -C $PROJECT pull || git clone $MAIN_REPOSITORY $PROJECT

  set_project_version_in_fuzz_targets_dependency

  #install
  (cd $PROJECT && $MVN install $MAVEN_ARGS)
  mvn -pl fuzz-targets install

else
  # Move seed corpus and dictionary.
  mv $SRC/{*.zip,*.dict} $OUT

  export JAVA_HOME="$OUT/open-jdk-17"
  mkdir -p $JAVA_HOME
  rsync -aL --exclude=*.zip "/usr/lib/jvm/java-17-openjdk-amd64/" "$JAVA_HOME"

  set_project_version_in_fuzz_targets_dependency

  #install
  (cd $PROJECT && $MVN install $MAVEN_ARGS -Dmaven.repo.local=$OUT/m2)
  $MVN -pl fuzz-targets install -Dmaven.repo.local=$OUT/m2

  # build classpath
  $MVN -pl fuzz-targets dependency:build-classpath -Dmdep.outputFile=cp.txt -Dmaven.repo.local=$OUT/m2
  cp -r $SRC/project-parent/fuzz-targets/target/test-classes $OUT/
  RUNTIME_CLASSPATH_ABSOLUTE="$(cat fuzz-targets/cp.txt):$OUT/test-classes"
  # replace dirname with placeholder $this_dir that will be replaced at runtime
  RUNTIME_CLASSPATH=$(echo $RUNTIME_CLASSPATH_ABSOLUTE | sed "s|$OUT|\$this_dir|g")

  for fuzzer in $(find $SRC/project-parent/fuzz-targets -name '*Fuzzer.java'); do
    fuzzer_basename=$(basename -s .java $fuzzer)

    # Create an execution wrapper for every fuzztarget
    echo "#!/bin/bash
  # LLVMFuzzerTestOneInput comment for fuzzer detection by infrastructure.
  this_dir=\$(dirname \"\$0\")
  if [[ \"\$@\" =~ (^| )-runs=[0-9]+($| ) ]]; then
    mem_settings='-Xmx1900m:-Xss900k'
  else
    mem_settings='-Xmx2048m:-Xss1024k'
  fi
  this_dir=\$(dirname \"\$0\")
  JAVA_HOME=\"\$this_dir/open-jdk-17/\" \
  LD_LIBRARY_PATH=\"\$this_dir/open-jdk-17/lib/server\":\$this_dir \
  \$this_dir/jazzer_driver --agent_path=\$this_dir/jazzer_agent_deploy.jar \
  --cp=$RUNTIME_CLASSPATH \
  --target_class=com.example.$fuzzer_basename \
  --jvm_args=\"\$mem_settings\" \
  \$@" > $OUT/$fuzzer_basename
    chmod u+x $OUT/$fuzzer_basename
  done

fi