require 'json'
require_relative './resource_names.rb'

MIGRATION_SCRIPT_FILENAME = "#{__dir__}/../../migration_script/laridae_migration.json"

def new_database_url(database_url, migration_script_json)
  migration_name = migration_script_json["name"]
  schema = migration_script_json["info"]["schema"]
  if database_url.include?('?')
    "#{database_url}&options=-csearch_path%3Dlaridae_#{migration_name},#{schema}"
  else
    "#{database_url}?options=-csearch_path%3Dlaridae_#{migration_name},#{schema}"
  end
end

def update_environment_variables(new_database_url)
  task_definition_str = `aws ecs describe-task-definition --task-definition #{RESOURCES["APP_TASK_DEFINITION_FAMILY"]} --region #{RESOURCES["REGION"]}`
  task_definition_json = JSON.parse(task_definition_str)
  unneeded_keys = ["taskDefinitionArn", "revision", "status", "requiresAttributes", "requiresCompatibilities", "registeredAt", "registeredBy", "compatibilities"]
  updated_json = Hash task_definition_json["taskDefinition"].filter { |key, value| !unneeded_keys.include?(key) }
  matching_container = updated_json["containerDefinitions"].find do |container_definition|
    container_definition["image"].include?(RESOURCES["APP_IMAGE_URL"])
  end
  db_environment_variable = matching_container["environment"].find do |environment_variable|
    environment_variable["name"] == RESOURCES["APP_DATABASE_URL_ENVIRONMENT_VARIABLE"]
  end
  db_environment_variable["value"] = new_database_url
  input_for_new_definition = JSON.generate(updated_json).gsub('"', '\\"')
  command = "aws ecs register-task-definition --region #{RESOURCES["REGION"]} --cli-input-json \"#{input_for_new_definition}\""
  `#{command}`
end

action = ARGV[0]

if File.exist?(MIGRATION_SCRIPT_FILENAME)
  migration_script = File.read(MIGRATION_SCRIPT_FILENAME).gsub('"', '\\"').gsub("\n", "\\n")
else
  migration_script = ''
end

COMMAND = <<~HEREDOC
aws ecs run-task \
  --region #{RESOURCES["REGION"]} \
  --cluster #{RESOURCES["LARIDAE_CLUSTER"]} \
  --task-definition #{RESOURCES["LARIDAE_TASK_DEFINITION"]} \
  --launch-type FARGATE \
  --network-configuration 'awsvpcConfiguration={subnets=[#{RESOURCES["SUBNET"]}],securityGroups=[#{RESOURCES["LARIDAE_SECURITY_GROUP"]}],assignPublicIp=ENABLED}' \
  --overrides file://env_override.json
HEREDOC

environment_override_file = File.open("env_override.json", 'w')
override_file_contents = <<~JSON
{
  "containerOverrides": [{
    "name": "laridae_migration_task",
    "environment": [
      {
        "name": "ACTION",
        "value": "#{action}"
      },
      {
        "name": "SCRIPT",
        "value": "#{migration_script}"
      }
    ]
  }]
}
JSON

if action == 'contract'
  puts "Waiting for service to redeploy..."
  `aws ecs wait services-stable --region #{RESOURCES["REGION"]} --cluster #{RESOURCES["APP_CLUSTER"]} --services #{RESOURCES["APP_SERVICE"]}`
  puts "Deployment complete."
end
puts "Spinning up Fargate task running laridae to #{action}"
environment_override_file.write(override_file_contents)
environment_override_file.close
task_creation_result = JSON.parse(`#{COMMAND}`)
task_id = task_creation_result['tasks'][0]['taskArn']
puts "Polling task status..."
loop do
  task_describe_result = JSON.parse(`aws ecs describe-tasks --region #{RESOURCES["REGION"]} --cluster "#{RESOURCES["LARIDAE_CLUSTER"]}" --tasks #{task_id}`)
  status = task_describe_result["tasks"][0]["attachments"][0]["status"]
  puts status
  break if status == 'DETACHED'
  sleep(15)
end
puts "Task complete!"
if action == 'expand'
  puts "Updating app task definition to reference post-migration schema."
  update_environment_variables(new_database_url(RESOURCES["DATABASE_URL"], migration_script))
end