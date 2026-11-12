FROM node:22-alpine
WORKDIR /app
ENV DATA_DIR=/app/data NODE_ENV=production
COPY package.json ./
COPY src ./src
# не от root: у процесса нет прав ни на что, кроме папки с данными
RUN mkdir -p /app/data && chown node:node /app/data
USER node
EXPOSE 7790/udp
VOLUME /app/data
CMD ["node", "src/index.js", "/app/config.json"]
