import { HttpClient, HttpErrorResponse, HttpHeaders } from '@angular/common/http';
import { Component, OnDestroy, OnInit, computed, inject, signal } from '@angular/core';

interface RuntimeConfig {
  apiBaseUrl: string;
}

interface DemoUser {
  id: string;
  name: string;
  initials: string;
  department: string;
  permissionSource: string;
  expected: 'allow' | 'deny';
}

interface HelloResponse {
  message: string;
  user: string;
}

interface AuthSession {
  accessToken: string;
  expiresAt: number;
  username: string;
  groups: string[];
}

interface StartSearchResponse {
  jobId: string;
  status: SearchJobStatus;
  statusUrl: string;
}

type SearchJobStatus = 'QUEUED' | 'RUNNING' | 'COMPLETED' | 'FAILED';

interface SearchJobResponse {
  jobId: string;
  status: SearchJobStatus;
  query: string;
  createdAt: string;
  updatedAt: string;
  scannedRecords: number;
  resultCount: number;
  downloadUrl?: string;
  downloadExpiresAt?: string;
  error?: string;
}

type FileJobStatus = 'WAITING_UPLOAD' | 'PROCESSING' | 'COMPLETED' | 'FAILED';

interface StartFileJobResponse {
  jobId: string;
  status: FileJobStatus;
  uploadUrl: string;
  uploadExpiresAt: string;
  requiredHeaders: Record<string, string>;
  statusUrl: string;
}

interface FileJobResponse {
  jobId: string;
  status: FileJobStatus;
  fileName: string;
  createdAt: string;
  updatedAt: string;
  sizeBytes: number;
  rowCount: number;
  columnCount: number;
  columns: string[];
  reportUrl?: string;
  reportExpiresAt?: string;
  error?: string;
}

type WorkflowJobStatus =
  | 'STARTING'
  | 'RUNNING'
  | 'SUCCEEDED'
  | 'FAILED'
  | 'TIMED_OUT'
  | 'ABORTED';

interface StartWorkflowResponse {
  jobId: string;
  status: WorkflowJobStatus;
  statusUrl: string;
}

interface WorkflowHistoryItem {
  name: string;
  enteredAt: string;
}

interface WorkflowOutput {
  outcome: string;
  processingLane: string;
  riskLevel: string;
  message: string;
  completedAt: string;
}

interface WorkflowJobResponse {
  jobId: string;
  status: WorkflowJobStatus;
  requestType: string;
  amount: number;
  startedAt?: string;
  stoppedAt?: string;
  currentStep?: string;
  history: WorkflowHistoryItem[];
  output?: WorkflowOutput;
  error?: string;
  cause?: string;
}

@Component({
  selector: 'app-root',
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App implements OnInit, OnDestroy {
  private readonly http = inject(HttpClient);
  private searchPollTimer?: ReturnType<typeof setTimeout>;
  private filePollTimer?: ReturnType<typeof setTimeout>;
  private workflowPollTimer?: ReturnType<typeof setTimeout>;

  protected readonly users: DemoUser[] = [
    { id: 'user-001', name: 'Alice', initials: 'AL', department: 'Engineering', permissionSource: '開発者グループ', expected: 'allow' },
    { id: 'user-003', name: 'Carol', initials: 'CA', department: 'Operations', permissionSource: 'ユーザー個別権限', expected: 'allow' },
    { id: 'user-002', name: 'Bob', initials: 'BO', department: 'Sales', permissionSource: '権限なし', expected: 'deny' },
  ];

  protected readonly selectedUserId = signal(this.users[0].id);
  protected readonly selectedUser = computed(
    () => this.users.find((user) => user.id === this.selectedUserId()) ?? this.users[0],
  );
  protected readonly apiBaseUrl = signal('');
  protected readonly authSession = signal<AuthSession | null>(null);
  protected readonly isAws = computed(
    () => this.apiBaseUrl() !== '' && !this.apiBaseUrl().includes('localhost'),
  );
  protected readonly environmentLabel = computed(() =>
    this.isAws() ? 'AWS development' : 'Local development',
  );
  protected readonly loading = signal(false);
  protected readonly authLoading = signal(false);
  protected readonly result = signal<HelloResponse | null>(null);
  protected readonly errorMessage = signal('');
  protected readonly httpStatus = signal<number | null>(null);
  protected readonly searchQuery = signal('engineering');
  protected readonly searchLoading = signal(false);
  protected readonly searchJob = signal<SearchJobResponse | null>(null);
  protected readonly searchError = signal('');
  protected readonly selectedFile = signal<File | null>(null);
  protected readonly fileLoading = signal(false);
  protected readonly filePhase = signal('');
  protected readonly fileJob = signal<FileJobResponse | null>(null);
  protected readonly fileError = signal('');
  protected readonly workflowRequestType = signal('purchase-approval');
  protected readonly workflowAmount = signal(250_000);
  protected readonly workflowLoading = signal(false);
  protected readonly workflowJob = signal<WorkflowJobResponse | null>(null);
  protected readonly workflowError = signal('');

  ngOnInit(): void {
    this.http.get<RuntimeConfig>('/config.json').subscribe({
      next: (config) => {
        this.apiBaseUrl.set(config.apiBaseUrl.replace(/\/$/, ''));
        if (this.isAws()) {
          this.loadAwsSession();
        }
      },
      error: () => this.errorMessage.set('config.json を読み込めませんでした。'),
    });
  }

  ngOnDestroy(): void {
    if (this.searchPollTimer) {
      clearTimeout(this.searchPollTimer);
    }
    if (this.filePollTimer) {
      clearTimeout(this.filePollTimer);
    }
    if (this.workflowPollTimer) {
      clearTimeout(this.workflowPollTimer);
    }
  }

  private loadAwsSession(): void {
    this.authLoading.set(true);
    this.http.get<AuthSession>('/auth/token').subscribe({
      next: (session) => {
        this.authSession.set(session);
        this.authLoading.set(false);
      },
      error: () => {
        this.errorMessage.set('ログイン情報を取得できませんでした。再ログインしてください。');
        this.authLoading.set(false);
      },
    });
  }

  protected selectUser(userId: string): void {
    this.selectedUserId.set(userId);
    this.result.set(null);
    this.errorMessage.set('');
    this.httpStatus.set(null);
    this.searchJob.set(null);
    this.searchError.set('');
    this.fileJob.set(null);
    this.fileError.set('');
    this.workflowJob.set(null);
    this.workflowError.set('');
  }

  protected callHelloApi(): void {
    if (!this.apiBaseUrl()) {
      this.errorMessage.set('API URLが未設定です。');
      return;
    }

    this.loading.set(true);
    this.result.set(null);
    this.errorMessage.set('');
    this.httpStatus.set(null);

    const token = this.authenticationToken();
    if (!token) {
      this.errorMessage.set('認証トークンがありません。再ログインしてください。');
      this.loading.set(false);
      return;
    }
    const headers = new HttpHeaders({ Authorization: `Bearer ${token}` });

    this.http
      .get<HelloResponse>(`${this.apiBaseUrl()}/api/hello`, { headers, observe: 'response' })
      .subscribe({
        next: (response) => {
          this.httpStatus.set(response.status);
          this.result.set(response.body);
          this.loading.set(false);
        },
        error: (error: HttpErrorResponse) => {
          this.httpStatus.set(error.status);
          this.errorMessage.set(
            error.status === 401 || error.status === 403
              ? 'Authorizerがこのユーザーのアクセスを拒否しました。'
              : `API呼び出しに失敗しました: ${error.message}`,
          );
          this.loading.set(false);
        },
      });
  }

  protected startSearch(): void {
    const query = this.searchQuery().trim();
    const token = this.authenticationToken();
    if (!this.apiBaseUrl() || !token) {
      this.searchError.set('API URLまたは認証トークンがありません。');
      return;
    }
    if (query.length < 2) {
      this.searchError.set('検索条件を2文字以上入力してください。');
      return;
    }

    if (this.searchPollTimer) {
      clearTimeout(this.searchPollTimer);
    }
    this.searchLoading.set(true);
    this.searchJob.set(null);
    this.searchError.set('');
    const headers = new HttpHeaders({ Authorization: `Bearer ${token}` });
    this.http
      .post<StartSearchResponse>(
        `${this.apiBaseUrl()}/api/search-jobs`,
        { query, maxResults: 250 },
        { headers },
      )
      .subscribe({
        next: (response) => {
          this.searchJob.set({
            jobId: response.jobId,
            status: response.status,
            query,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
            scannedRecords: 0,
            resultCount: 0,
          });
          this.pollSearch(response.jobId, headers);
        },
        error: (error: HttpErrorResponse) => {
          this.searchLoading.set(false);
          this.searchError.set(
            error.status === 401 || error.status === 403
              ? 'このユーザーには非同期検索を実行する権限がありません。'
              : `検索ジョブを開始できませんでした: ${error.message}`,
          );
        },
      });
  }

  private pollSearch(jobId: string, headers: HttpHeaders): void {
    this.searchPollTimer = setTimeout(() => {
      this.http
        .get<SearchJobResponse>(`${this.apiBaseUrl()}/api/search-jobs/${jobId}`, { headers })
        .subscribe({
          next: (job) => {
            this.searchJob.set(job);
            if (job.status === 'QUEUED' || job.status === 'RUNNING') {
              this.pollSearch(jobId, headers);
              return;
            }
            this.searchLoading.set(false);
            if (job.status === 'FAILED') {
              this.searchError.set(job.error ?? '検索処理が失敗しました。');
            }
          },
          error: (error: HttpErrorResponse) => {
            this.searchLoading.set(false);
            this.searchError.set(`検索状態を取得できませんでした: ${error.message}`);
          },
        });
    }, 800);
  }

  protected selectCsv(event: Event): void {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0] ?? null;
    this.fileJob.set(null);
    this.fileError.set('');
    if (file && !file.name.toLowerCase().endsWith('.csv')) {
      this.selectedFile.set(null);
      this.fileError.set('CSVファイルを選択してください。');
      return;
    }
    if (file && file.size > 2 * 1024 * 1024) {
      this.selectedFile.set(null);
      this.fileError.set('サンプルでは2 MiB以下のCSVを選択してください。');
      return;
    }
    this.selectedFile.set(file);
  }

  protected uploadSelectedCsv(): void {
    const file = this.selectedFile();
    if (!file) {
      this.fileError.set('アップロードするCSVを選択してください。');
      return;
    }
    this.startFileIngest(file);
  }

  protected uploadSampleCsv(): void {
    const csv = [
      'employeeId,name,department',
      '1,Alice,engineering',
      '2,Bob,sales',
      '3,Carol,operations',
      '',
    ].join('\n');
    this.startFileIngest(new File([csv], 'sample-employees.csv', { type: 'text/csv' }));
  }

  private startFileIngest(file: File): void {
    const token = this.authenticationToken();
    if (!this.apiBaseUrl() || !token) {
      this.fileError.set('API URLまたは認証トークンがありません。');
      return;
    }
    if (this.filePollTimer) {
      clearTimeout(this.filePollTimer);
    }

    this.fileLoading.set(true);
    this.filePhase.set('署名付きURLを発行中');
    this.fileJob.set(null);
    this.fileError.set('');
    const apiHeaders = new HttpHeaders({ Authorization: `Bearer ${token}` });
    this.http
      .post<StartFileJobResponse>(
        `${this.apiBaseUrl()}/api/file-jobs`,
        { fileName: file.name },
        { headers: apiHeaders },
      )
      .subscribe({
        next: (job) => {
          this.fileJob.set({
            jobId: job.jobId,
            status: job.status,
            fileName: file.name,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
            sizeBytes: file.size,
            rowCount: 0,
            columnCount: 0,
            columns: [],
          });
          this.filePhase.set('S3へ直接アップロード中');
          const uploadHeaders = new HttpHeaders(job.requiredHeaders);
          this.http
            .put(job.uploadUrl, file, { headers: uploadHeaders, responseType: 'text' })
            .subscribe({
              next: () => {
                this.filePhase.set('S3 Eventの処理を待機中');
                this.pollFileJob(job.jobId, apiHeaders);
              },
              error: (error: HttpErrorResponse) => {
                this.fileLoading.set(false);
                this.fileError.set(`S3へアップロードできませんでした: ${error.message}`);
              },
            });
        },
        error: (error: HttpErrorResponse) => {
          this.fileLoading.set(false);
          this.fileError.set(
            error.status === 401 || error.status === 403
              ? 'このユーザーにはCSVアップロードを実行する権限がありません。'
              : `ファイルジョブを開始できませんでした: ${error.message}`,
          );
        },
      });
  }

  private pollFileJob(jobId: string, headers: HttpHeaders): void {
    this.filePollTimer = setTimeout(() => {
      this.http
        .get<FileJobResponse>(`${this.apiBaseUrl()}/api/file-jobs/${jobId}`, { headers })
        .subscribe({
          next: (job) => {
            this.fileJob.set(job);
            if (job.status === 'WAITING_UPLOAD' || job.status === 'PROCESSING') {
              this.pollFileJob(jobId, headers);
              return;
            }
            this.fileLoading.set(false);
            this.filePhase.set('');
            if (job.status === 'FAILED') {
              this.fileError.set(job.error ?? 'CSV処理が失敗しました。');
            }
          },
          error: (error: HttpErrorResponse) => {
            this.fileLoading.set(false);
            this.filePhase.set('');
            this.fileError.set(`ファイル処理状態を取得できませんでした: ${error.message}`);
          },
        });
    }, 800);
  }

  protected startWorkflow(): void {
    const requestType = this.workflowRequestType().trim();
    const amount = this.workflowAmount();
    const token = this.authenticationToken();
    if (!this.apiBaseUrl() || !token) {
      this.workflowError.set('API URLまたは認証トークンがありません。');
      return;
    }
    if (requestType.length < 2 || !Number.isFinite(amount) || amount <= 0) {
      this.workflowError.set('申請種別と0より大きい金額を入力してください。');
      return;
    }
    if (this.workflowPollTimer) {
      clearTimeout(this.workflowPollTimer);
    }

    this.workflowLoading.set(true);
    this.workflowJob.set(null);
    this.workflowError.set('');
    const headers = new HttpHeaders({ Authorization: `Bearer ${token}` });
    this.http
      .post<StartWorkflowResponse>(
        `${this.apiBaseUrl()}/api/workflow-jobs`,
        { requestType, amount },
        { headers },
      )
      .subscribe({
        next: (response) => {
          this.workflowJob.set({
            jobId: response.jobId,
            status: response.status,
            requestType,
            amount,
            history: [],
          });
          this.pollWorkflow(response.jobId, headers);
        },
        error: (error: HttpErrorResponse) => {
          this.workflowLoading.set(false);
          this.workflowError.set(
            error.status === 401 || error.status === 403
              ? 'このユーザーにはワークフローを実行する権限がありません。'
              : `ワークフローを開始できませんでした: ${error.message}`,
          );
        },
      });
  }

  protected setWorkflowAmount(value: string): void {
    this.workflowAmount.set(Number(value));
  }

  private pollWorkflow(jobId: string, headers: HttpHeaders): void {
    this.workflowPollTimer = setTimeout(() => {
      this.http
        .get<WorkflowJobResponse>(`${this.apiBaseUrl()}/api/workflow-jobs/${jobId}`, { headers })
        .subscribe({
          next: (job) => {
            this.workflowJob.set(job);
            if (job.status === 'STARTING' || job.status === 'RUNNING') {
              this.pollWorkflow(jobId, headers);
              return;
            }
            this.workflowLoading.set(false);
            if (job.status !== 'SUCCEEDED') {
              this.workflowError.set(job.cause ?? job.error ?? 'ワークフローが失敗しました。');
            }
          },
          error: (error: HttpErrorResponse) => {
            this.workflowLoading.set(false);
            this.workflowError.set(`ワークフロー状態を取得できませんでした: ${error.message}`);
          },
        });
    }, 600);
  }

  private authenticationToken(): string | undefined {
    return this.isAws()
      ? this.authSession()?.accessToken
      : `local:${this.selectedUser().id}`;
  }
}
