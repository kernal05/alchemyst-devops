FROM node:20-slim
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY tsconfig.json .
COPY src/ src/
COPY iii.worker.yaml .

RUN npm install -D tsx typescript @types/node

ENV III_URL=ws://iii-engine:49134

CMD ["npx", "tsx", "src/worker.ts"]
