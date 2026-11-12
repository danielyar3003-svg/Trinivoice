FROM node:22-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
EXPOSE 7790/udp
CMD ["node", "src/index.js", "/app/config.json"]
