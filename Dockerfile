FROM node:22-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm install --omit=dev

COPY server.js ./
COPY public ./public
RUN mkdir -p /app/uploads /app/data

VOLUME ["/app/uploads", "/app/data"]
EXPOSE 3000
ENV PORT=3000
CMD ["node", "server.js"]
