terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = "us-east-1"
}

################################
# 1. S3 Buckets
################################
resource "aws_s3_bucket" "weather" {
  bucket        = "transformedweatherapi"
  force_destroy = true
}

resource "aws_s3_bucket" "athena_results" {
  bucket        = "weather-athena-results-12345"
  force_destroy = true
}

################################
# 2. Kinesis Stream
################################
resource "aws_kinesis_stream" "weather_ingest" {
  name        = "weather-ingest-stream"
  shard_count = 1
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

################################
# 3. IAM Role for Lambdas
################################
resource "aws_iam_role" "lambda_role" {
  name = "weather-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-s3-kinesis-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "arn:aws:s3:::${aws_s3_bucket.weather.bucket}/*"
      },
      {
        Effect   = "Allow",
        Action   = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListStreams"
        ],
        Resource = aws_kinesis_stream.weather_ingest.arn
      }
    ]
  })
}

################################
# 4. Lambdas
################################
# Producer Lambda (reads Kinesis)
resource "aws_lambda_function" "producer" {
  function_name = "weather-producer-lambda"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"

  filename         = "producer.zip"   # <-- your producer code
  source_code_hash = filebase64sha256("producer.zip")
}

# Transform Lambda (cleans & writes to S3)
resource "aws_lambda_function" "transform" {
  function_name = "weather-transform-to-s3"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"

  filename         = "lambda.zip"   # <-- your transform code
  source_code_hash = filebase64sha256("lambda.zip")

  environment {
    variables = {
      OUTPUT_BUCKET = aws_s3_bucket.weather.bucket
      OUTPUT_PREFIX = "curated/weather/"
    }
  }
}

################################
# 5. Glue Database & Crawler
################################
resource "aws_glue_catalog_database" "weather_db" {
  name = "weather_db"
}

resource "aws_glue_crawler" "weather" {
  name          = "weather_curated_crawler"
  role          = aws_iam_role.lambda_role.arn
  database_name = aws_glue_catalog_database.weather_db.name

  s3_target {
    path = "s3://${aws_s3_bucket.weather.bucket}/curated/weather/"
  }
}

################################
# 6. Athena
################################
resource "aws_athena_workgroup" "weather" {
  name = "weather_workgroup"
  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/"
    }
  }
}

resource "aws_athena_named_query" "sample_query" {
  name      = "WeatherSampleQuery"
  database  = aws_glue_catalog_database.weather_db.name
  workgroup = aws_athena_workgroup.weather.name
  query     = <<EOT
SELECT location, temp_c, humidity, condition, ingest_ts
FROM transformedweatherapi
LIMIT 10;
EOT
}

################################
# 7. Step Functions
################################
resource "aws_iam_role" "step_role" {
  name = "weather-step-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "states.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "step_policy" {
  name = "weather-step-policy"
  role = aws_iam_role.step_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["lambda:InvokeFunction", "glue:StartCrawler", "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "weather_pipeline" {
  name     = "weather-pipeline-workflow"
  role_arn = aws_iam_role.step_role.arn

  definition = jsonencode({
    Comment = "Weather pipeline: Kinesis -> Producer Lambda -> Transform Lambda -> S3 -> Glue -> Athena",
    StartAt = "ReadFromKinesis",
    States = {
      ReadFromKinesis = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.producer.arn
        },
        Next = "TransformLambda"
      },
      TransformLambda = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.transform.arn
        },
        Next = "StartGlueCrawler"
      },
      StartGlueCrawler = {
        Type     = "Task",
        Resource = "arn:aws:states:::glue:startCrawler.sync",
        Parameters = {
          Name = aws_glue_crawler.weather.name
        },
        Next = "RunAthenaQuery"
      },
      RunAthenaQuery = {
        Type     = "Task",
        Resource = "arn:aws:states:::athena:startQueryExecution.sync",
        Parameters = {
          QueryString = aws_athena_named_query.sample_query.query,
          WorkGroup   = aws_athena_workgroup.weather.name
        },
        End = true
      }
    }
  })
}
