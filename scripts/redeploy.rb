require 'json'
require_relative './resource_names.rb'

MIGRATION_SCRIPT_FILENAME = "#{__dir__}/../../migration_script/laridae_migration.json"

# add check for if file doesn't exist
migration_json = JSON.parse(File.read(MIGRATION_SCRIPT_FILENAME))

ECR_URL = RESOURCES["APP_IMAGE_URL"].split("/")[0...-1].join("/")

# Note that us-east-1 in the first command must be us-east-1; it doesn't depend on the user's region
COMMAND = <<HEREDOC
cd repo
echo "Pushing new docker image..."
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin #{ECR_URL}
docker build -t #{RESOURCES["IMAGE_NAME"]}:${GITHUB_SHA} .
docker tag #{RESOURCES["IMAGE_NAME"]}:${GITHUB_SHA} #{RESOURCES["APP_IMAGE_URL"]}:${GITHUB_SHA}
docker tag #{RESOURCES["IMAGE_NAME"]}:${GITHUB_SHA} #{RESOURCES["APP_IMAGE_URL"]}:latest
docker push #{RESOURCES["APP_IMAGE_URL"]}:${GITHUB_SHA}
docker push #{RESOURCES["APP_IMAGE_URL"]}:latest
echo "Updating service..."
aws ecs update-service --region #{RESOURCES["REGION"]} --cluster #{RESOURCES["APP_CLUSTER"]} --service #{RESOURCES["APP_SERVICE"]} --task-definition #{RESOURCES["APP_TASK_DEFINITION_FAMILY"]} --force-new-deployment
echo "Waiting for service to redeploy..."
aws ecs wait services-stable --region #{RESOURCES["REGION"]} --cluster #{RESOURCES["APP_CLUSTER"]} --services #{RESOURCES["APP_SERVICE"]}
echo "Deployment complete!"
HEREDOC
`#{COMMAND}`
