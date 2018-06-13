function [B, D] = dmf(R, varargin)
%%% [B,D]=dmf(R, 'K', 64, 'max_iter', 30, 'debug', true, 'loss', 'logit', 'beta', 0.01, 'lambda', 0.01);
%%% optimize 
%%% \sum_{(i,j)\in \Omega} \ell(r_{ij}, b_i'd_j) + 
%%% \rho \sum_{(i,j)\notin \Omega} (b_i'd_j)^2 + 
%%% \alpha(|B-P_b|_F^2 + |D-Q_b|_F^2) + 
%%% \beta (|B-P_d|_F^2 + |D-Q_d|_F^2)
%%% s.t. P_b'1=0, Q_b'1=0, P_d'P_d=I and B_d'B_d=I.
%%% R rating matrix of size m x n
%%% K dimension of hamming space
%%% max_iter the max number of iterations
%%% loss loss function for optimization
%%% rho regularization coefficient for interaction/implicit regularization
%%% alpha regularization coefficient for balanced condition
%%% beta  regularization coefficient for decorrelation condition
[m, n]=size(R);
[k, max_iter, debug, islogit, alpha, beta, rho, alg, bsize] = process_options(varargin, 'K', 64, 'max_iter', 10, 'debug', true, ...
    'islogit', false, 'alpha',0.01, 'beta', 0.01, 'rho', 0.01, 'alg', 'ccd','blocksize',32);
if ~islogit
    R = scale_matrix(R, k);
end
rng(10);
B = +(randn(m,k)>0); D = +(randn(n,k)>0);
B = B*2-1; D=D*2-1;
Rt = R.';
opt.rho = rho;
opt.alpha = alpha;
opt.beta = beta;
opt.islogit = islogit;
opt.alg = alg;
opt.bsize = bsize;
for iter=1:max_iter
    P_b = B-repmat(mean(B),m,1); P_d = sqrt(m) * proj_stiefel_manifold(B);
    Q_b = D-repmat(mean(D),n,1); Q_d = sqrt(n) * proj_stiefel_manifold(D);
    loss = loss_(R, B, D, opt) + opt.alpha * (norm(B-P_b,'fro')^2 + norm(D-Q_b,'fro')^2) ...
        + opt.beta*(norm(B-P_d,'fro')^2 +norm(D-Q_d,'fro')^2);
    fprintf('Iteration=%3d of all optimization, loss=%10.3f\n', iter-1, loss);
    DtD = D'*D;
    B = optimize(Rt, D, B, DtD, P_b, P_d, opt);
    %XX = opt.alpha*P_b + opt.beta*P_d;
    %B2 = dcmf_all_mex(Rt, D, B, XX, DtD*opt.rho, 1, islogit);
    BtB = B'*B;
    D = optimize(R,  B, D, BtB, Q_b, Q_d, opt);
    %YY = opt.alpha*P_b + opt.beta*P_d;
    %D = dcmf_all_mex(R, B, D, YY, BtB*opt.rho, 100, islogit);
end
    P_b = B-repmat(mean(B),m,1); P_d = sqrt(m) * proj_stiefel_manifold(B);
    Q_b = D-repmat(mean(D),n,1); Q_d = sqrt(n) * proj_stiefel_manifold(D);
    loss = loss_(R, B, D, opt) + opt.alpha * (norm(B-P_b,'fro')^2 + norm(D-Q_b,'fro')^2) ...
        + opt.beta*(norm(B-P_d,'fro')^2 +norm(D-Q_d,'fro')^2);
    fprintf('Iteration=%3d of all optimization, loss=%10.3f\n', iter, loss);
end

function B = optimize(Rt, D, B, DtD, P_b, P_d, opt)
max_iter = 1;
m = size(Rt, 2);
lambda = @(x) tanh((abs(x)+1e-16)/2)./(abs(x)+1e-16)./4;
X = opt.alpha*P_b + opt.beta*P_d;
for u=1:m
    %fprintf('%d,',u);
    b = B(u,:);
    r = Rt(:,u);
    idx = r ~= 0;
    Du = D(idx, :);
    if ~opt.islogit
        H = opt.rho * DtD + (1 - opt.rho) * (Du.' * Du);
        %H = opt.rho * DtD + (Du.' * Du);
        f = Du.' * r(idx) + X(u,:).';
        B(u,:) = bqp(b.', (H+H')/2, f, 'alg', opt.alg, 'max_iter',max_iter, 'blocksize', opt.bsize);
        %r_ = Du * b.';
        %B(u,:) = ccd_logit_mex(r(idx), Du, b, [], X(u,:), r_, opt.islogit, max_iter);
    else
        if ~strcmpi(opt.alg,'ccd')
            r_ = Du * b.';
            H = opt.rho * DtD + Du.' * diag(lambda(r_) - opt.rho) * Du;
            %H = opt.rho * DtD + Du.' * diag(lambda(r_)) * Du;
            f = 1/4 * Du.' * r(idx) + X(u,:).';
            B(u,:) = bqp(b, (H+H')/2, f, 'alg', opt.alg, 'max_iter',max_iter, 'blocksize', opt.bsize);
        else
            r_ = Du * b.';
            B(u,:) = ccd_logit_mex(r(idx), Du, b, opt.rho * (DtD - Du'*Du), X(u,:), r_, opt.islogit, max_iter);
            %B(u,:) = ccd_logit_mex(r(idx), Du, b, opt.rho * DtD, X(u,:), r_, opt.islogit, max_iter);
        end
    end
end
end

function R = scale_matrix(R, s)
maxS = max(max(R));
minS = min(R(R>0));
[I, J, V] = find(R);
if maxS ~= minS
    VV = (V-minS)/(maxS-minS);
    VV = 2 * s * VV - s + 1e-10;
else
    VV = V .* s ./ maxS;
end
R = sparse(I, J, VV, size(R,1), size(R,2));
end

function W = proj_stiefel_manifold(A)
%%% min_W |A - W|_F^2, s.t. W^T W = I
[U, ~, V] = svd(A, 0);
W = U * V.';
end

function val = loss_(R, P, Q, opt)
[I,J,r] = find(R);
r_ = sum(P(I,:) .* Q(J,:), 2);
if opt.islogit
    val = sum(log(1+exp(-r .* r_))) - opt.rho * sum(r_.^2);
else
    val = sum((r - r_).^2) - opt.rho * sum(r_.^2);
end
val = val + opt.rho*sum(sum((P'*P) .* (Q'*Q)));
end
