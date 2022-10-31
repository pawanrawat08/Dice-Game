%
function varargout = mtspofs_ga_depots(varargin)
    
    
    %
    % Initialize default configuration
    %
    defaultConfig.xy          = 10*rand(40,2);
    defaultConfig.dmat        = [];
    defaultConfig.nSalesmen   = 5;
    defaultConfig.minTour     = 2;
    defaultConfig.popSize     = 160;
    defaultConfig.numIter     = 5e3;
    defaultConfig.showProg    = true;
    defaultConfig.showStatus  = true;
    defaultConfig.showResult  = true;
    defaultConfig.showWaitbar = false;
    
    
    %
    % Interpret user configuration inputs
    %
    if ~nargin
        userConfig = struct();
    elseif isstruct(varargin{1})
        userConfig = varargin{1};
    else
        try
            userConfig = struct(varargin{:});
        catch
            error('??? Expected inputs are either a structure or parameter/value pairs');
        end
    end
    
    
    %
    % Override default configuration with user inputs
    %
    configStruct = get_config(defaultConfig,userConfig);
    
    
    %
    % Extract configuration
    %
    xy          = configStruct.xy;
    dmat        = configStruct.dmat;
    nSalesmen   = configStruct.nSalesmen;
    minTour     = configStruct.minTour;
    popSize     = configStruct.popSize;
    numIter     = configStruct.numIter;
    showProg    = configStruct.showProg;
    showStatus  = configStruct.showStatus;
    showResult  = configStruct.showResult;
    showWaitbar = configStruct.showWaitbar;
    if isempty(dmat)
        nPoints = size(xy,1);
        a = meshgrid(1:nPoints);
        dmat = reshape(sqrt(sum((xy(a,:)-xy(a',:)).^2,2)),nPoints,nPoints);
    end
    
    
    %
    % Verify inputs
    %
    [N,dims] = size(xy);
    [nr,nc] = size(dmat);
    if (N ~= nr) || (N ~= nc)
        error('??? Invalid XY or DMAT inputs')
    end
    n = N - 2*nSalesmen;
    
    
    %
    % Sanity checks
    % nSalesmen = max(1,min(n,round(real(nSalesmen(1)))));
    minTour     = max(1,min(floor(n/nSalesmen),round(real(minTour(1)))));
    popSize     = max(16,16*ceil(popSize(1)/16));
    numIter     = max(1,round(real(numIter(1))));
    showProg    = logical(showProg(1));
    showStatus  = logical(showStatus(1));
    showResult  = logical(showResult(1));
    showWaitbar = logical(showWaitbar(1));
    
    
    %
    % Initializations for route break point selection
    %
    nBreaks = nSalesmen-1;
    dof = n - minTour*nSalesmen;          % degrees of freedom
    addto = ones(1,dof+1);
    for k = 2:nBreaks
        addto = cumsum(addto);
    end
    cumProb = cumsum(addto)/sum(addto);
    
    
    %
    % Initialize the populations
    %
    popRoute = zeros(popSize,n);         % population of routes
    popBreak = zeros(popSize,nBreaks);   % population of breaks
    popDepot = zeros(popSize,nSalesmen); % population of breaks
    popRoute(1,:) = (1:n) + nSalesmen;
    popBreak(1,:) = rand_breaks();
    popDepot(1,:) = rand_depots();
    for k = 2:popSize
        popRoute(k,:) = randperm(n) + nSalesmen;
        popBreak(k,:) = rand_breaks();
        popDepot(k,:) = rand_depots();
    end
    
    
    %
    % Seed the algorithm with a previous result if available
    %
    if all(isfield(userConfig,{'optRoute','optBreak','optDepot'}))
        optRoute = userConfig.optRoute;
        optBreak = userConfig.optBreak;
        optDepot = userConfig.optDepot;
        isValidRoute = isequal(popRoute(1,:),sort(optRoute));
        isValidBreak = all(optBreak > 0) && all(optBreak <= n) && ...
            (length(optBreak) == nBreaks) && ~any(mod(optBreak,1));
        isValidDepot = all(optDepot > N-nSalesmen) && all(optDepot <= N) && ...
            (length(optDepot) == nSalesmen) && ~any(mod(optDepot,1));
        if isValidRoute && isValidBreak && isValidDepot
            popRoute(1,:) = optRoute;
            popBreak(1,:) = optBreak;
            popDepot(1,:) = optDepot;
        end
    end
    
    
    %
    % Select the colors for the plotted routes
    %
    pclr = ~get(0,'DefaultAxesColor');
    clr = [1 0 0; 0 0 1; 0.67 0 1; 0 1 0; 1 0.5 0];
    if (nSalesmen > 5)
        clr = hsv(nSalesmen);
    end
    
    
    %
    % Run the GA
    %
    row = zeros(popSize,n+nSalesmen);
    col = zeros(popSize,n+nSalesmen);
    isValid = false(1,n+nSalesmen);
    globalMin = Inf;
    distHistory = NaN(1,numIter);
    tmpPopRoute = zeros(16,n);
    tmpPopBreak = zeros(16,nBreaks);
    tmpPopDepot = zeros(16,nSalesmen);
    newPopRoute = zeros(popSize,n);
    newPopBreak = zeros(popSize,nBreaks);
    newPopDepot = zeros(popSize,nSalesmen);
    [isClosed,isStopped,isCancelled] = deal(false);
    if showProg
        hFig = figure('Name','MTSPOFS_GA_DEPOTS | Current Best Solution', ...
            'Numbertitle','off','CloseRequestFcn',@close_request);
        hAx = gca;
        if showStatus
            [hStatus,isCancelled] = figstatus(0,numIter,[],hFig);
        end
    end
    if showWaitbar
        hWait = waitbar(0,'Searching for near-optimal solution ...', ...
            'CreateCancelBtn',@cancel_search);
    end
    isRunning = true;
    for iter = 1:numIter
        
        %
        % EVALUATE SOLUTIONS
        %   This section of code computes the total cost of each solution
        %   in the population. The actual code that gets executed uses a
        %   much faster (vectorized) method to calculate the route lengths
        %   compared to the triple for-loop below (provided for reference)
        %   but gives the same result.
        %
        %     totalDist = zeros(popSize,1);
        %     for p = 1:popSize
        %         d = 0;
        %         pRoute = popRoute(p,:);
        %         pBreak = popBreak(p,:);
        %         pDepot = popDepot(p,:);
        %         rng = [[1 pBreak+1];[pBreak n]]';
        %         for s = 1:nSalesmen
        %             d = d + dmat(s,pRoute(rng(s,1)));
        %             for k = rng(s,1):rng(s,2)-1
        %                 d = d + dmat(pRoute(k),pRoute(k+1));
        %             end
        %             d = d + dmat(pRoute(rng(s,2)),pDepot(s));
        %         end
        %         totalDist(p) = d;
        %     end
        %
        for p = 1:popSize
            brk = popBreak(p,:);
            dep = popDepot(p,:);
            isValid(:) = false;
            isValid([1 brk+(2:nSalesmen)]) = true;
            row(p,isValid) = (1:nSalesmen);
            row(p,~isValid) = popRoute(p,:);
            isValid(:) = false;
            isValid([brk+(1:nSalesmen-1) n+nSalesmen]) = true;
            col(p,isValid) = dep;
            col(p,~isValid) = popRoute(p,:);
        end
        ind = N*(col-1) + row;
        totalDist = sum(dmat(ind),2);
        
        
        %
        % SELECT THE BEST
        %   This section of code finds the best solution in the current
        %   population and stores it if it is better than the previous best.
        %
        [minDist,index] = min(totalDist);
        distHistory(iter) = minDist;
        if (minDist < globalMin)
            globalMin = minDist;
            optRoute = popRoute(index,:);
            optBreak = popBreak(index,:);
            optDepot = popDepot(index,:);
            rng = [[1 optBreak+1];[optBreak n]]';
            if showProg
                
                %
                % Plot the best route
                %
                for s = 1:nSalesmen
                    rte = [s optRoute(rng(s,1):rng(s,2)) optDepot(s)];
                    e = optDepot(s);
                    if (dims > 2), plot3(hAx,xy(rte,1),xy(rte,2),xy(rte,3),'.-','Color',clr(s,:));
                    else, plot(hAx,xy(rte,1),xy(rte,2),'.-','Color',clr(s,:)); end
                    hold(hAx,'on');
                    if (dims > 2), plot3(hAx,xy(s,1),xy(s,2),xy(s,3),'s','Color',clr(s,:));
                    else, plot(hAx,xy(s,1),xy(s,2),'s','Color',clr(s,:)); end
                    if (dims > 2), plot3(hAx,xy(e,1),xy(e,2),xy(e,3),'o','Color',pclr);
                    else, plot(hAx,xy(e,1),xy(e,2),'o','Color',pclr); end
                end
                title(hAx,sprintf('Total Distance = %1.4f, Iteration = %d',minDist,iter));
                hold(hAx,'off');
                drawnow;
            end
        end
        
        
        %
        % Update the status bar and check cancellation status
        %
        if showProg && showStatus && ~mod(iter,ceil(numIter/100))
            [hStatus,isCancelled] = figstatus(iter,numIter,hStatus,hFig);
        end
        if (isStopped || isCancelled)
            break
        end
        
        
        %
        % MODIFY THE POPULATION
        %   This section of code invokes the genetic algorithm operators.
        %   In this implementation, solutions are randomly assigned to groups
        %   of sixteen and the best solution is kept (tournament selection).
        %   The best-of-sixteen solution is then mutated 3 different ways
        %   (flip, swap, and slide) and the four resulting solutions are
        %   then copied but assigned different break points to complete a
        %   group of eight. Those eight are then copied and assigned randomly
        %   to the depots. There is no crossover operator because it tends
        %   to be highly destructive and rarely improves a decent solution.
        %
        randomOrder = randperm(popSize);
        for p = 16:16:popSize
            rtes = popRoute(randomOrder(p-15:p),:);
            brks = popBreak(randomOrder(p-15:p),:);
            dpts = popDepot(randomOrder(p-15:p),:);
            dists = totalDist(randomOrder(p-15:p));
            [ignore,idx] = min(dists); %#ok
            bestOf8Route = rtes(idx,:);
            bestOf8Break = brks(idx,:);
            bestOf8Depot = dpts(idx,:);
            routeInsertionPoints = sort(randperm(n,2));
            I = routeInsertionPoints(1);
            J = routeInsertionPoints(2);
            for k = 1:16 % Generate new solutions
                tmpPopRoute(k,:) = bestOf8Route;
                tmpPopBreak(k,:) = bestOf8Break;
                tmpPopDepot(k,:) = bestOf8Depot;
                switch k
                    case 2 % Flip
                        tmpPopRoute(k,I:J) = tmpPopRoute(k,J:-1:I);
                    case 3 % Swap
                        tmpPopRoute(k,[I J]) = tmpPopRoute(k,[J I]);
                    case 4 % Slide
                        tmpPopRoute(k,I:J) = tmpPopRoute(k,[I+1:J I]);
                    case 5 % Modify breaks
                        tmpPopBreak(k,:) = rand_breaks();
                    case 6 % Flip, modify breaks
                        tmpPopRoute(k,I:J) = tmpPopRoute(k,J:-1:I);
                        tmpPopBreak(k,:) = rand_breaks();
                    case 7 % Swap, modify breaks
                        tmpPopRoute(k,[I J]) = tmpPopRoute(k,[J I]);
                        tmpPopBreak(k,:) = rand_breaks();
                    case 8 % Slide, modify breaks
                        tmpPopRoute(k,I:J) = tmpPopRoute(k,[I+1:J I]);
                        tmpPopBreak(k,:) = rand_breaks();
                    case 9 % Modify depots
                        tmpPopDepot(k,:) = rand_depots();
                    case 10 % Modify breaks, modify depots
                        tmpPopBreak(k,:) = rand_breaks();
                        tmpPopDepot(k,:) = rand_depots();
                    case 11 % Flip, modify depots
                        tmpPopRoute(k,I:J) = tmpPopRoute(k,J:-1:I);
                        tmpPopDepot(k,:) = rand_depots();
                    case 12 % Swap, modify depots
                        tmpPopRoute(k,[I J]) = tmpPopRoute(k,[J I]);
                        tmpPopDepot(k,:) = rand_depots();
                    case 13 % Slide, modify depots
                        tmpPopRoute(k,I:J) = tmpPopRoute(k,[I+1:J I]);
                        tmpPopDepot(k,:) = rand_depots();
                    case 14 % Flip, modify breaks, modify depots
                        tmpPopRoute(k,I:J) = tmpPopRoute(k,J:-1:I);
                        tmpPopBreak(k,:) = rand_breaks();
                        tmpPopDepot(k,:) = rand_depots();
                    case 15 % Swap, modify breaks, modify depots
                        tmpPopRoute(k,[I J]) = tmpPopRoute(k,[J I]);
                        tmpPopBreak(k,:) = rand_breaks();
                        tmpPopDepot(k,:) = rand_depots();
                    case 16 % Slide, modify breaks, modify depots
                        tmpPopRoute(k,I:J) = tmpPopRoute(k,[I+1:J I]);
                        tmpPopBreak(k,:) = rand_breaks();
                        tmpPopDepot(k,:) = rand_depots();
                    otherwise % Do nothing
                end
            end
            newPopRoute(p-15:p,:) = tmpPopRoute;
            newPopBreak(p-15:p,:) = tmpPopBreak;
            newPopDepot(p-15:p,:) = tmpPopDepot;
        end
        popRoute = newPopRoute;
        popBreak = newPopBreak;
        popDepot = newPopDepot;
        
        
        %
        % Update the waitbar
        %
        if showWaitbar && ~mod(iter,ceil(numIter/325))
            waitbar(iter/numIter,hWait);
        end
        
    end
    if showProg && showStatus
        figstatus(numIter,numIter,hStatus,hFig);
    end
    if showWaitbar
        delete(hWait);
    end
    isRunning = false;
    if isClosed
        delete(hFig);
    end
    
    
    %
    % Append prior distance history if present
    %
    if isfield(userConfig,'distHistory')
        priorHistory = userConfig.distHistory;
        isNan = isnan(priorHistory);
        distHistory = [priorHistory(~isNan) distHistory];
    end
    
    
    %
    % Format the optimal solution
    %
    optSolution = cell(nSalesmen,1);
    rng = [[1 optBreak+1];[optBreak n]]';
    for s = 1:nSalesmen
        optSolution{s} = [s optRoute(rng(s,1):rng(s,2)) optDepot(s)];
    end
    
    
    %
    % Show the final results
    %
    if showResult
        
        %
        % Plot the GA results
        %
        figure('Name','MTSPOFS_GA_DEPOTS | Results','Numbertitle','off');
        subplot(2,2,1);
        if (dims > 2), plot3(xy(:,1),xy(:,2),xy(:,3),'.','Color',pclr);
        else, plot(xy(:,1),xy(:,2),'.','Color',pclr); end
        hold on
        for s = 1:nSalesmen
            if (dims > 2), plot3(xy(s,1),xy(s,2),xy(s,3),'s','Color',pclr);
            else, plot(xy(s,1),xy(s,2),'s','Color',clr(s,:)); end
        end
        e = optDepot;
        if (dims > 2), plot3(xy(e,1),xy(e,2),xy(e,3),'o','Color',pclr);
        else, plot(xy(e,1),xy(e,2),'o','Color',pclr); end
        title('City Locations');
        subplot(2,2,2);
        s = (1:nSalesmen);
        imagesc(dmat([s optRoute e],[s optRoute e]));
        title('Distance Matrix');
        subplot(2,2,3);
        for s = 1:nSalesmen
            rte = optSolution{s};
            if (dims > 2), plot3(xy(rte,1),xy(rte,2),xy(rte,3),'.-','Color',clr(s,:));
            else, plot(xy(rte,1),xy(rte,2),'.-','Color',clr(s,:)); end
            hold on
            if (dims > 2), plot3(xy(s,1),xy(s,2),xy(s,3),'s','Color',clr(s,:));
            else, plot(xy(s,1),xy(s,2),'s','Color',clr(s,:)); end
        end
        if (dims > 2), plot3(xy(e,1),xy(e,2),xy(e,3),'o','Color',pclr);
        else, plot(xy(e,1),xy(e,2),'o','Color',pclr); end
        title(sprintf('Total Distance = %1.4f',minDist));
        subplot(2,2,4);
        plot(distHistory,'b','LineWidth',2);
        title('Best Solution History');
        set(gca,'XLim',[1 length(distHistory)],'YLim',[0 1.1*max([1 distHistory])]);
    end
    
    
    %
    % Return output
    %
    if nargout
        
        %
        % Create anonymous functions for plot generation
        %
        plotPoints  = @(s)plot(s.xy(:,1),s.xy(:,2),'.','Color',~get(gca,'Color'));
        plotResult  = @(s)cellfun(@(s,i)plot(s.xy(i,1),s.xy(i,2),'.-', ...
            'Color',rand(1,3)),repmat({s},size(s.optSolution)),s.optSolution);
        plotHistory = @(s)plot(s.distHistory,'b-','LineWidth',2);
        plotMatrix  = @(s)imagesc(s.dmat(cat(2,s.optSolution{:}),cat(2,s.optSolution{:})));
        
        
        %
        % Save results in output structure
        %
        resultStruct = struct( ...
            'xy',          xy, ...
            'dmat',        dmat, ...
            'nSalesmen',   nSalesmen, ...
            'minTour',     minTour, ...
            'popSize',     popSize, ...
            'numIter',     numIter, ...
            'showProg',    showProg, ...
            'showResult',  showResult, ...
            'showWaitbar', showWaitbar, ...
            'optRoute',    optRoute, ...
            'optBreak',    optBreak, ...
            'optDepot',    optDepot, ...
            'optSolution', {optSolution}, ...
            'plotPoints',  plotPoints, ...
            'plotResult',  plotResult, ...
            'plotHistory', plotHistory, ...
            'plotMatrix',  plotMatrix, ...
            'distHistory', distHistory, ...
            'minDist',     minDist);
        
        varargout = {resultStruct};
        
    end
    
    
    %
    % Generate random set of break points
    %
    function breaks = rand_breaks()
        if (minTour == 1) % No constraints on breaks
            breaks = sort(randperm(n-1,nBreaks));
        else % Force breaks to be at least the minimum tour length
            nAdjust = find(rand < cumProb,1)-1;
            spaces = randi(nBreaks,1,nAdjust);
            adjust = zeros(1,nBreaks);
            for kk = 1:nBreaks
                adjust(kk) = sum(spaces == kk);
            end
            breaks = minTour*(1:nBreaks) + cumsum(adjust);
        end
    end
    
    
    %
    % Generate random set of depot end points
    %
    function depots = rand_depots()
        depots = randperm(nSalesmen) + N - nSalesmen;
    end
    
    
    %
    % Nested function to cancel search
    %
    function cancel_search(varargin)
        isStopped = true;
    end
    
    
    %
    % Nested function to close the figure window
    %
    function close_request(varargin)
        if isRunning
            [isClosed,isStopped] = deal(true);
            isRunning = false;
        else
            delete(hFig);
        end
    end
    
end

