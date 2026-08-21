# Bedrock AgentCore Runtime container.
# AgentCore requires a linux/arm64 image exposing port 8080.
FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .

# Default port of the AgentCore Runtime contract
EXPOSE 8080

# Observability: OTEL/X-Ray instrumentation can be enabled via ADOT.
# For this sample, AgentCore already emits basic traces when the role has permission.
CMD ["python", "agent.py"]
