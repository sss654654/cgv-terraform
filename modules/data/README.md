# modules/data — 클러스터 밖으로 뺀 둘

```
 ┌─ EKS nodes (cluster security group) ─────────────────────┐
 │    booking                        queue                  │
 └──────┬───────────┬────────────────┬──────────────────────┘
        │ 3306      │ 6379           │ 6379
        │           │ TLS + AUTH     │ TLS + AUTH
 ┌──────┼───────────┼────────────────┼─ data SG ────────────┐
 │      v           └───────┬────────┘                      │
 │  RDS MySQL 8.4           v                               │
 │  primary + standby   ElastiCache Redis 7.1               │
 │  (Multi-AZ, sync)    primary + replica, auto failover    │
 └──────────────────────────────────────────────────────────┘
   Secrets Manager (RDS master, Redis AUTH) ──> cgv-infra secrets.sh
```

## 무엇을 관리형으로 뺐나 — 칸마다 근거가 다르다

| 대상 | 결정 | 정한 것 |
|---|---|---|
| MySQL | RDS | **목적.** 담긴 것이 시드뿐이라 데이터 보호가 이유가 아니다. prd 에서 MySQL 을 파드로 안 돌리므로 전환에서 무엇이 걸리는지 보려는 것 |
| Redis | ElastiCache · 클러스터 모드 끔 | **코드.** 대기열 Lua 가 해시태그 키와 태그 없는 전역 키를 한 호출에 섞어, Cluster Mode 에서는 `CROSSSLOT` 으로 거부된다 |
| Kafka | 관리형 안 씀 | **비용.** MSK 가 하루 약 $3.6 으로 60배 — 클러스터 안 Strimzi 로 둔다 |

집에서는 고를 것이 없었다. 노트북 한 대 환경에 "클러스터 밖"이라는 자리가 없어 미들웨어가 전부 파드였다.

---

## 두 서비스 나란히

| | RDS MySQL | ElastiCache Redis |
|---|---|---|
| 스펙 | 8.4 · db.m5.large · gp3 20 GiB 암호화 | 7.1 · cache.m5.large · 저장 암호화 |
| 이중화 | Multi-AZ — 커밋이 대기의 기록까지 기다린다 | 주 1 + 복제본 1 · 자동 전환 · Multi-AZ — 복제는 비동기 |
| 처리량에 보태나 | 대기는 읽기를 안 받는다 | 앱이 주 엔드포인트만 쓴다 |
| 두는 이유 | prd 와 같은 쓰기 지연 조건으로 재려고 | Kafka 를 AZ 셋에 둔 것과 짝 — Redis 가 한 AZ 에만 있으면 AZ 설계가 한쪽만 성립 |
| 비밀번호 | `manage_master_user_password` — AWS 가 만들어 Secrets Manager 에. **state 에 안 남는다** | `random_password` → Secrets Manager `<prefix>-redis-auth`. state 에 남는다(state 버킷 암호화) |
| 전송 암호화 | 끔 — `require_secure_transport=0` (앱이 JDBC `useSSL=false` · 담긴 것이 데모 시드) | **켬 + AUTH** |
| 파라미터 | — | `maxmemory-policy noeviction` (기본 volatile-lru 는 만료 없는 키를 지울 수 있다) |
| 백업 | 없음 · 최종 스냅숏 없음 · 삭제 방지 없음 | 스냅숏 없음 |
| 지원 정책 | `engine_lifecycle_support` 끔 — 표준 지원만 | — |
| YACE 가 찾는 태그 | Name | Name |

---

## Redis 에 암호화와 AUTH 를 켠 이유

- 이것이 없으면 6379 에 닿는 파드 하나가 **대기열 · 좌석 락 · 입장 인증 전권**을 갖는다. 보안 그룹은 "어디서 오는가"만 보고 "누구인가"는 안 본다.
- ElastiCache 는 전송 암호화를 켜야 AUTH 를 받는다 — 프로토콜이 평문이라 비밀번호가 그대로 흐르기 때문이다.
- 노드 ↔ ElastiCache 는 VPC 안이지만 관리형 서비스 구간이라 인스턴스 간 자동 암호화의 보장 밖이다.
- 대가로 Redis CPU 를 더 쓴다. 실서비스 조건에서 잰 값이 진짜 상한이라 켠 채로 쟀다.

### 떠 있는 그룹에 무중단으로 붙이는 순서

빈 그룹을 새로 만들면 기본값(`required` · `SET`)으로 한 번에 된다. **이미 떠 있는 평문 그룹**에만 AWS 가 두 단계씩을 요구한다.

```
transit preferred ─> 앱 재기동 ─> transit required ─> auth ROTATE ─> auth SET
평문·TLS 둘 다       TLS·비밀번호   평문 끊음            토큰 추가        토큰만
```

```
terraform apply -var redis_transit_encryption_mode=preferred
# cgv-infra secrets.sh → queue · booking 재기동
terraform apply                                               # required
terraform apply -var redis_auth_token_update_strategy=ROTATE
terraform apply                                               # SET
```

preferred 인 동안은 평문 연결이 살아 있어 보안 그룹이 유일한 방어다. 오래 두지 않는다.

> [!WARNING]
> **암호화를 켜면 주 엔드포인트 이름이 바뀐다.**
> 평문 `<이름>.<조각>.ng.0001.<리전>.cache.amazonaws.com` → 암호화 `master.<이름>.<조각>.<리전>.cache.amazonaws.com`
> 서버 인증서가 새 이름에만 맞아, 옛 이름으로 붙으면 `x509: certificate is valid for …` 로 끊긴다. 앱의 `REDIS_HOST` 를 같이 바꾼다.

---

## 보안 그룹

| 규칙 | 값 |
|---|---|
| 인바운드 3306 | EKS 클러스터 보안 그룹에서 |
| 인바운드 6379 | EKS 클러스터 보안 그룹에서 |
| 아웃바운드 | **없음** — Terraform 이 AWS 기본 "전체 허용"을 지우고 코드에 적은 것만 남긴다. 보안 그룹은 상태를 기억해 들어온 연결의 응답은 나간다 |

> [!NOTE]
> 보안 그룹이 노드의 네트워크 인터페이스에 붙어, 노드 위 **어느 파드든** 통과한다. 집에서 DB 파드에 걸었던 "booking · queue 만 받는다"가 노드 단위로 느슨해진다. 파드 단위 구분은 cgv-infra 의 앱 출구 NetworkPolicy 가 맡는다. prd 는 Security Groups for Pods.

---

## 지울 때

| 시크릿 | 지워지는 방법 |
|---|---|
| RDS 마스터 비밀번호 | Terraform 자원이 아니지만 인스턴스를 지우면 AWS 가 같이 지운다 |
| Redis AUTH (`<prefix>-redis-auth`) | `recovery_window_in_days = 0` — destroy 와 함께 즉시. 기본 30일 유예면 다음에 같은 이름을 만들 때 "삭제 예정"과 부딪혀 apply 가 멈춘다 |

---

## 입력 · 출력

| 입력 | 무엇 |
|---|---|
| `prefix` · `vpc_id` · `subnet_ids` | 이름 · 자리 |
| `node_security_group_id` | 들어오게 할 출처 — modules/eks 의 클러스터 보안 그룹 |
| `mysql_version` · `rds_instance_class` · `rds_parameter_family` · `db_name` · `db_username` · `rds_multi_az` | RDS |
| `redis_version` · `redis_node_type` · `redis_parameter_family` · `redis_replicas` | ElastiCache |
| `redis_transit_encryption_mode` · `redis_auth_token_update_strategy` | 무중단 전환 중에만 `-var` 로 바꾼다 |

| 출력 | 받는 곳 |
|---|---|
| `mysql_host` · `redis_host` | `envs/stg` 출력 `handoff` → cgv-infra `envs/stg/{booking,queue}.yaml` |
| `mysql_secret_arn` · `redis_secret_arn` | `handoff` → cgv-infra `secrets.sh` |
| `data_security_group_id` | 대조용 |
