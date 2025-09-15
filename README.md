Problem statement :
A real-time pipeline that collects external data (such as weather), processes and filters it, and stores the refined data for analytics and alerting.
I designed and implement this using only AWS cloud services, while applying best practices for orchestration, logging, and alerting.

Target State :
The goal is to design and implement a fully automated, serverless, real-time data engineering pipeline on AWS that ingests data from a public API, transforms it in real time, and stores it in a cloud-native data lake (Amazon S3) for analytics and reporting.

Project Overview : 

This project demonstrates an end-to-end data pipeline that ingests live weather data from an external API, processes and transforms the data, stores it in Amazon S3 in a structured format, and makes it queryable using Amazon Athena. The entire workflow is orchestrated using AWS Step Functions and monitored using CloudWatch with alerts sent via SNS.
The goal of this project is to showcase how to design a production-style data pipeline that can handle streaming data, ensure data quality through transformation, and provide queryable insights for downstream analysis.

Architecture :

1. A Python producer script fetches live weather data from the Weather API.
2. The raw JSON data is ingested into an Amazon Kinesis Data Stream.
3. An AWS Lambda function consumes records from Kinesis, applies transformation and cleaning, and stores the cleaned data in Amazon S3.
4. The data is stored in partitioned folders in S3 (dt=YYYY/MM/DD/HH) as compressed JSON files for efficient querying.
5. An AWS Glue Crawler scans the S3 bucket and updates the Glue Data Catalog with schema information.
6. Amazon Athena uses the Glue Catalog metadata to run SQL queries directly against the data in S3.
7. AWS Step Functions orchestrates the workflow, ensuring ingestion, transformation, cataloging, and querying run in sequence.
8. CloudWatch monitors the pipeline, and SNS sends alerts if errors or failures occur.

Components Used :

Weather API: Data source for live weather data.
Amazon Kinesis Data Stream: Streaming ingestion service.
AWS Lambda: Transformation and cleaning of raw weather records.
Amazon S3: Storage for cleaned, structured, and partitioned data.
AWS Glue: Schema discovery and metadata management.
Amazon Athena: Querying data with SQL directly from S3.
AWS Step Functions: Workflow orchestration of the pipeline.
Amazon CloudWatch: Monitoring and logging for pipeline components.
Amazon SNS: Alerting via email for failures or data issues.

About Terraform.tf :

I wrote a Terraform script to define the AWS resources used in this project. The script provisions the Kinesis stream, S3 bucket, Lambda functions, Glue crawler, Athena workgroup, Step Functions workflow, and CloudWatch monitoring components. The main reason for writing this script was to practice Infrastructure as Code (IaC). While I initially created many resources manually to understand how each service works, I captured them in Terraform so the entire setup can be reproduced consistently in the future with a single command. This reduces manual effort, avoids configuration drift, and demonstrates how real-world data pipelines are deployed and managed at scale.

Repo structure:
ingest_weather.py – script to fetch weather data and send it to Kinesis.
lambda.py – Lambda code to transform records and store them in S3.
stepfunction.json – Step Functions definition for orchestrating the pipeline.
terraform.code – Terraform script to provision all AWS resources for the pipeline.
