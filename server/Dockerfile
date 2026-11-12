FROM node:22-alpine
WORKDIR /app
ENV DATA_DIR=/app/data
COPY package.json ./
COPY src ./src
EXPOSE 7790/udp
VOLUME /app/data
CMD ["node", "src/index.js", "/app/config.json"]
