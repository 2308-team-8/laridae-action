<div align="center">
  <img width="300" src="https://i.ibb.co/q7FMJ9p/Transparent-Logo.png" alt="Laridae-Logo" >
</div>

# Overview

Laridae (LAIR-ih-day) is an open-source tool that enables reversible, zero-downtime schema migrations in PostgreSQL. It allows application instances expecting the pre-migration and post-migration schema to use the same database simultaneously without requiring changes to either version's code. Additionally, recent schema migrations can be reversed without data loss. This is accomplished with minimal interference with usual reads and writes to the database.

The Laridae GitHub action integrates this schema migration functionality into your CI/CD workflow on GitHub actions, synchronizing it with your app deployment. It currently supports deployments on AWS Fargate. We discuss the details of how to use the action below, but to briefly summarize: Once you add the action to your workflow, if you need to deploy code that requires a schema change, you include a migration script in the commit to your repo specifying the schema change. The action will:

- Modify your database so that it presents either the old or updated schema depending on what parameters are used in the database URL when connecting.
- Update the database URL referenced by your new code so that it uses the updated schema.
- Wait for your new code to be deployed, and then remove support for the old schema from the database.

For more details on Laridae, see

- [Our website](https://laridae-migrations.github.io/), with a detailed write-up.
- [The Laridae GitHub](https://github.com/laridae-migrations/laridae) (this repo is specifically for the action).

# Initialization

Laridae expects that you have a Fargate service deployed to AWS using an AWS-hosted PostgreSQL database. Before using the action, in order for Laridae to access your private database, you need to run our initialization script.

The script creates several pieces of AWS infrastructure:

- An IAM user with limited permissions and access keys for this user the GitHub runner assumes when performing a migration.
- An ECS cluster, capacity provider, and task definition which the runner uses to create a task which runs the migration, as well as the necessary IAM roles for these.
- A security group the task runs in.

It also permits traffic on port 5432 form the created security group to your PostgreSQL database's security group.

It has the following dependencies:

- AWS CLI
- Ruby (≥ 2.7.5)
- Bundler
- Terraform

Here's how to use the script:

1. First, clone the laridae-initialization repo:\
   `git clone https://github.com/laridae-migrations/laridae-initialization`
2. Create a JSON document containing the names of the relevant AWS infrastructure pieces that are already in place. Here's an example:

```json
{
  "REGION": "us-east-1",
  "IMAGE_NAME": "todo-test-app",
  "APP_CLUSTER": "todo-test-app-cluster",
  "APP_TASK_DEFINITION_FAMILY": "todo-test-app-task-definition",
  "APP_IMAGE_URL": "public.ecr.aws/m8a3j7h3/todo-test-app",
  "APP_SERVICE": "todo-test-app-service",
  "APP_DATABASE_URL_ENVIRONMENT_VARIABLE": "DATABASE_URL",
  "DATABASE_URL": "postgresql://user:password@hostname/region",
  "DATABASE_SECURITY_GROUP": "sg-012ccfea25537bcb3",
  "SUBNET": "subnet-0032bde34aff97563",
  "VPC_ID": "vpc-06b34f632d5a20c3b"
}
```

Laridae requires the app to store the database URL inside an environment variable in its task definition. The name of this environment variable is provided under the key `APP_DATABASE_URL_ENVIRONMENT_VARIABLE`.

3. Navigate into to the initialization repo directory and install the necessary dependencies:\
   `cd laridae-initialization`\
   `bundle install`

4. Run the initialization script, passing it the path to the JSON document you created:\
   `ruby initialize.rb [path to JSON document describe resources]`

The script will output a secret that should be added to your GitHub repo that lets it know the names of the existing and newly created resources, as well as the access keys for the created IAM user.

# Adding action to workflow

The action is intended be added to an existing workflow which deploys your Fargate app when new code is pushed.

The action takes two inputs:

- `command`: either `expand` or `contract`.
- `aws-resource-names`: the secret output by the initialization script above containing AWS resource names and access keys.

When given the command `expand`, the action looks for a migration script in the latest commit and modifies your database so that it presents either the pre-migration or post-migration schema depending on the exact database URL you use. It also modifies the app so that its URL references the post-migration schema.

When given the command `contract`, it modifies the database to remove support for the pre-migration schema.

The intended use case is to sandwich your existing deployment between the expand and contract like so:

```YAML
- uses: laridae-migrations/laridae-action
        with:
          command: expand
          aws-resource-names: ${{secrets.LARIDAE_RESOURCE_NAMES}}
#
# Existing deployment steps...
#
- uses: laridae-migrations/laridae-action
        with:
          command: expand
          aws-resource-names: ${{secrets.LARIDAE_RESOURCE_NAMES}}
```

This way, by the time the new code is deployed, the database can support it, and by the time the database is contracted, no old code is running.

If you do not already have a Fargate deployment workflow, the following sample workflow includes the Laridae actions as well as a simple Fargate deployment. It assumes that your Fargate task definition references the `latest` tag of an image in a public ECR repo:

```yaml
name: Laridae sample workflow
on:
  push:
    branches:
      - main
jobs:
  expand:
    runs-on: ubuntu-latest
    steps:
      - uses: laridae-migrations/laridae-action
        with:
          command: expand
          aws-resource-names: ${{secrets.LARIDAE_RESOURCE_NAMES}}
    deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: laridae-migrations/laridae-action
        with:
          command: sample-deploy
          aws-resource-names: ${{secrets.LARIDAE_RESOURCE_NAMES}}
    contract:
    runs-on: ubuntu-latest
    steps:
      - uses: laridae-migrations/laridae-action
        with:
          command: contract
          aws-resource-names: ${{secrets.LARIDAE_RESOURCE_NAMES}}
```

# Using the action

Once the action has been added to your workflow, whenever the workflow is triggered, the action will look for a migration script called `laridae_migration.json` in the root directory of your repo, expanding and contracting based on that script. For details on the migration script format, see [the `README` in the Laridae GitHub](https://github.com/laridae-migrations/laridae). If multiple consecutive commits have the same migration script, no additional changes to the database will be made.
