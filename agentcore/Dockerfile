# Container do Bedrock AgentCore Runtime.
# AgentCore exige imagem linux/arm64 expondo a porta 8080.
FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .

# Porta padrao do contrato do AgentCore Runtime
EXPOSE 8080

# Observabilidade: instrumentacao OTEL/X-Ray pode ser ligada via ADOT.
# Para a PoC, o AgentCore ja entrega traces basicos quando a role tem permissao.
CMD ["python", "agent.py"]
